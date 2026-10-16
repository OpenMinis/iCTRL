import CryptoKit
import Foundation
import Network

class JSONRPCServer {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    /// Connections handed off to a long-lived streamer (video) — the base receive
    /// loop must not cancel these.
    private var handedOff: Set<ObjectIdentifier> = []
    /// Connections accepted by the nearby (peer-to-peer) listener.
    private var nearbyConnections: Set<ObjectIdentifier> = []
    private var nearbyListener: NWListener?
    private var nearbyAdvertiser: NearbyAdvertiser?
    /// Port of the nearby listener: one above the main port.
    var nearbyPort: UInt16 { port &+ 1 }
    /// Nearby advertising state, readable from any thread. `.off` while nearby
    /// discovery is not running.
    var nearbyStatus: NearbyAdvertiser.Status {
        nearbyStatusLock.lock(); defer { nearbyStatusLock.unlock() }
        return nearbyStatusValue
    }
    var isNearbyAdvertising: Bool { nearbyStatus == .advertising }
    private var nearbyStatusValue: NearbyAdvertiser.Status = .off
    private let nearbyStatusLock = NSLock()
    /// Called (on the server queue) whenever `nearbyStatus` changes.
    var onNearbyStateChange: ((NearbyAdvertiser.Status) -> Void)?
    let port: UInt16
    private let localOnly: Bool
    private let queue = DispatchQueue(label: "com.openminis.ictrl.server")
    private(set) var isRunning = false

    var onRPCRequest: ((String, [String: JSONValue]?, @escaping ([String: JSONValue]?, JSONRPCError?) -> Void) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    /// Hand off an authorized connection to the video streamer (host owns the
    /// frame grabber + VideoStreamer). The server stops managing this connection
    /// once handed off — the streamer keeps it alive and closes it on disconnect.
    var onVideoStream: ((NWConnection, _ fps: Double, _ quality: String, _ verbose: Bool) -> Void)?

    /// Fired right after a UI-mutating JSON-RPC completes (tap, swipe, home, …)
    /// so the host can nudge the video pipeline to emit a keyframe immediately
    /// instead of waiting for the next 1/fps tick — cuts perceived click-to-
    /// reflect latency at low fps.
    var onRPCUIChanged: (() -> Void)?
    /// Returns redacted log text for the (auth-required) GET /logs endpoint.
    var onLogsRequest: (() -> String)?

    /// Lists persisted daily log files (names + sizes) for GET /logs/files.
    var onLogFilesRequest: (() -> String)?

    /// Returns the redacted contents of a persisted log file for
    /// GET /logs/history?date=YYYY-MM-DD (defaults to today if absent).
    var onLogHistoryRequest: ((String?) -> String)?

    /// Routes internal server-lifecycle messages to the host's log sink so they
    /// land in the persisted log file, not just the console.
    var onLog: ((String) -> Void)?

    private func log(_ message: String) {
        onLog?(message)
        print(message)
    }

    init(port: UInt16 = 8200, localOnly: Bool = false) {
        self.port = port
        self.localOnly = localOnly
    }

    func start() throws {
        guard !isRunning else { return }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "JSONRPCServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port"])
        }

        let listener: NWListener
        if localOnly {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
            listener = try NWListener(using: params)
        } else {
            listener = try NWListener(using: params, on: nwPort)
        }
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.isRunning = true
                self.onStateChange?(true)
                self.log("🟢 iCTRL server ready on port \(self.port)")
            case .failed(let error):
                self.log("🔴 Server failed: \(error)")
                self.isRunning = false
                self.onStateChange?(false)
            case .cancelled:
                self.isRunning = false
                self.onStateChange?(false)
                self.log("⚪️ NWListener cancelled")
            case .waiting(let error):
                self.log("🟡 NWListener waiting: \(error)")
            case .setup:
                self.log("🔧 NWListener setup")
            @unknown default:
                self.log("❔ NWListener state: \(state)")
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            // Peer-to-peer peers belong to the nearby listener, which is only
            // open while the user has turned nearby discovery on. Without this
            // check, any AWDL link the device happens to have would reach 8200.
            if Self.isPeerToPeer(conn) {
                self.log("🚫 Refused \(conn.endpoint) on port \(self.port): peer-to-peer connections use the nearby listener")
                conn.cancel()
                return
            }
            self.handleConnection(conn)
        }

        listener.start(queue: queue)
        log("🔊 NWListener.start called (port \(port), localOnly=\(localOnly))")
    }

    func stop() {
        log("🔻 JSONRPCServer.stop called")
        // Nearby teardown belongs on the server queue, where that state lives.
        // Hand over the objects rather than self: stop() also runs from deinit.
        let nearbyListener = self.nearbyListener, nearbyAdvertiser = self.nearbyAdvertiser
        queue.async { [weak self] in self?.nearbyWanted = false }
        self.nearbyListener = nil
        self.nearbyAdvertiser = nil
        nearbyConnections.removeAll()
        queue.async {
            nearbyAdvertiser?.stop()
            nearbyListener?.cancel()
        }
        connections.forEach { $0.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        isRunning = false
        log("🔴 iCTRL server stopped")
    }

    // MARK: - Nearby (peer-to-peer) listener

    /// Open the nearby listener and advertise it over AWDL.
    ///
    /// A separate listener so it can be switched on and off on its own and
    /// accept peer-to-peer connections only; anything arriving over another
    /// interface is refused. Not available while the server is local-only.
    func startNearby() {
        queue.async {
            self.nearbyWanted = true
            self.nearbyRetryDelay = 5
            self.startNearbyOnQueue()
        }
    }

    func stopNearby() {
        queue.async {
            self.nearbyWanted = false
            self.stopNearbyOnQueue()
        }
    }

    /// Nearby discovery should be running (on `queue`): a failed listener is
    /// rebuilt while this holds, instead of leaving discovery dead until it
    /// is switched off and on again.
    private var nearbyWanted = false
    /// Back-off for rebuilding a failed nearby listener; reset once it is ready.
    private var nearbyRetryDelay: TimeInterval = 5

    private func scheduleNearbyRebuild() {
        let delay = nearbyRetryDelay
        nearbyRetryDelay = min(nearbyRetryDelay * 2, 30)
        log("📡 Nearby: rebuilding the listener in \(Int(delay))s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.nearbyWanted, self.nearbyListener == nil else { return }
            self.startNearbyOnQueue()
        }
    }

    /// Re-advertise under the current `NearbyIdentity.name`.
    func refreshNearbyName() {
        queue.async { self.nearbyAdvertiser?.refreshName() }
    }

    /// Re-check the peer-to-peer interface now (call on network changes).
    func recheckNearby() {
        queue.async { self.nearbyAdvertiser?.recheck() }
    }

    /// Retry a refused nearby registration without waiting for the back-off.
    func retryNearbyNow() {
        queue.async { self.nearbyAdvertiser?.retryNow() }
    }

    private func setNearbyStatus(_ status: NearbyAdvertiser.Status) {
        nearbyStatusLock.lock()
        let changed = nearbyStatusValue != status
        nearbyStatusValue = status
        nearbyStatusLock.unlock()
        if changed { onNearbyStateChange?(status) }
    }

    private func startNearbyOnQueue() {
        guard !localOnly, nearbyListener == nil else { return }
        guard nearbyPort != 0, let nwPort = NWEndpoint.Port(rawValue: nearbyPort) else {
            // listen_port 65535 leaves no port above it for the nearby listener.
            log("📡 Nearby: no port above \(port) for the nearby listener")
            setNearbyStatus(.failed)
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true
        guard let l = try? NWListener(using: params, on: nwPort) else {
            log("📡 Nearby: could not open port \(nearbyPort)")
            setNearbyStatus(.failed)
            if nearbyWanted { scheduleNearbyRebuild() }
            return
        }
        l.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.log("📡 Nearby listener ready on port \(self.nearbyPort) (peer-to-peer only)")
                self.nearbyRetryDelay = 5
            case .failed(let error):
                // Advertising a listener that is gone would only mislead
                // clients: take both down, then rebuild while still wanted.
                self.log("📡 Nearby listener failed: \(error)")
                self.stopNearbyOnQueue()
                self.setNearbyStatus(.failed)
                if self.nearbyWanted { self.scheduleNearbyRebuild() }
            case .waiting(let error):
                self.log("📡 Nearby listener waiting: \(error)")
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            guard Self.isPeerToPeer(conn) else {
                self.log("🚫 Refused \(conn.endpoint) on nearby port \(self.nearbyPort): not a peer-to-peer connection")
                conn.cancel()
                return
            }
            self.log("📡 Nearby connection from \(conn.endpoint)")
            self.nearbyConnections.insert(ObjectIdentifier(conn))
            self.handleConnection(conn)
        }
        l.start(queue: queue)
        nearbyListener = l

        let advertiser = NearbyAdvertiser(port: nearbyPort, lanPort: port, queue: queue) { [weak self] in self?.log($0) }
        advertiser.onChange = { [weak self] status in self?.setNearbyStatus(status) }
        nearbyAdvertiser = advertiser
        advertiser.start()
    }

    private func stopNearbyOnQueue() {
        guard nearbyListener != nil || nearbyAdvertiser != nil else { return }
        nearbyAdvertiser?.stop()
        nearbyAdvertiser = nil
        nearbyListener?.cancel()
        nearbyListener = nil
        for conn in connections where nearbyConnections.contains(ObjectIdentifier(conn)) { conn.cancel() }
        nearbyConnections.removeAll()
        setNearbyStatus(.off)
        log("📡 Nearby discovery stopped")
    }

    /// The remote address (no port, no zone) and how it arrived, for the
    /// session list.
    ///
    /// Built from `NWConnection.endpoint`, raw address bytes and getifaddrs
    /// only — see `isLoopback(_:)` for why the newer Network properties
    /// (`IPv4Address.isLoopback`, `currentPath`, …) must not be touched here:
    /// on the oldest supported iOS their symbols are missing at load time.
    static func peer(of connection: NWConnection) -> (address: String, via: String)? {
        guard case let .hostPort(host, _) = connection.endpoint else { return nil }
        var v4: [UInt8]?
        var zone: String?
        var address: String
        switch host {
        case .ipv4(let a):
            v4 = [UInt8](a.rawValue)
            address = v4!.map(String.init).joined(separator: ".")
        case .ipv6(let a):
            let b = [UInt8](a.rawValue)
            if b.count == 16, b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff {
                v4 = Array(b[12..<16])                       // IPv4-mapped
                address = v4!.map(String.init).joined(separator: ".")
            } else {
                var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                let ok = b.withUnsafeBytes { inet_ntop(AF_INET6, $0.baseAddress, &text, socklen_t(text.count)) } != nil
                address = ok ? String(cString: text) : "\(a)"
                if b.count == 16, b[0..<15].allSatisfy({ $0 == 0 }), b[15] == 1 { return (address, PeerSource.local.rawValue) }
                zone = Self.zone(of: a)                        // link-local: the interface it came in on
            }
        case .name(let n, _):
            address = n
        @unknown default:
            return nil
        }
        if let pct = address.firstIndex(of: "%") { address = String(address[..<pct]) }
        if let v4, v4.first == 127 { return (address, PeerSource.local.rawValue) }

        let name = zone ?? v4.flatMap(Self.interfaceName(containing:))
        guard let name else { return (address, PeerSource.other.rawValue) }
        let via: PeerSource
        if name.hasPrefix("awdl") || name.hasPrefix("llw") { via = .nearby }
        else if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { via = .vpn }
        else if name.hasPrefix("pdp_ip") { via = .cellular }
        else if name.hasPrefix("lo") { via = .local }
        else if name.hasPrefix("en") || name.hasPrefix("bridge") { via = .lan }
        else { via = .other }
        return (address, via.rawValue)
    }

    /// The local interface whose IPv4 subnet holds `addr` (point-to-point
    /// links: whose peer address is `addr`), or nil.
    private static func interfaceName(containing addr: [UInt8]) -> String? {
        guard addr.count == 4 else { return nil }
        let peer = UInt32(addr[0]) << 24 | UInt32(addr[1]) << 16 | UInt32(addr[2]) << 8 | UInt32(addr[3])
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        func v4(_ sa: UnsafeMutablePointer<sockaddr>?) -> UInt32? {
            guard let sa, sa.pointee.sa_family == UInt8(AF_INET) else { return nil }
            return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
        }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let mine = v4(ifa.ifa_addr) else { continue }
            if ifa.ifa_flags & UInt32(IFF_POINTOPOINT) != 0 {
                if v4(ifa.ifa_dstaddr) == peer { return String(cString: ifa.ifa_name) }
            } else if let mask = v4(ifa.ifa_netmask), mask != 0, mine & mask == peer & mask {
                return String(cString: ifa.ifa_name)
            }
        }
        return nil
    }

    /// Whether a connection arrived over peer-to-peer Wi-Fi (AWDL / low-latency
    /// WLAN). Those peers always use IPv6 link-local addresses scoped to the
    /// interface, so the endpoint alone answers it — no newer path API needed.
    static func isPeerToPeer(_ connection: NWConnection) -> Bool {
        guard case let .hostPort(host, _) = connection.endpoint, case let .ipv6(addr) = host,
              let name = zone(of: addr) else { return false }
        return name.hasPrefix("awdl") || name.hasPrefix("llw")
    }

    /// The zone (interface name) of a scoped IPv6 address, from its text form
    /// ("fe80::1%awdl0") — iOS 12-era API only, see `isLoopback(_:)`.
    private static func zone(of addr: IPv6Address) -> String? {
        let text = "\(addr)"
        guard let pct = text.firstIndex(of: "%") else { return nil }
        let name = String(text[text.index(after: pct)...])
        return name.isEmpty ? nil : name
    }

    private func isNearby(_ connection: NWConnection) -> Bool {
        nearbyConnections.contains(ObjectIdentifier(connection))
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connections.append(connection)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveHTTP(from: connection)
            case .failed, .cancelled:
                self?.removeConnection(connection)
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func receiveHTTP(from connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            var acc = buffer
            if let data = data, !data.isEmpty { acc.append(data) }

            // A full HTTP request needs the header terminator AND, for a body, the
            // whole Content-Length. If we don't have it all yet, keep receiving —
            // TCP can split a request across segments (common under concurrent /
            // rapid requests), and parsing a half-received body was the cause of
            // spurious "parse error" responses.
            switch Self.requestState(of: acc) {
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()  // peer closed before sending it all
                } else {
                    self.receiveHTTP(from: connection, buffer: acc)  // wait for more
                }
            case .complete(let headerEnd, let contentLength):
                self.processHTTPRequest(acc, headerEnd: headerEnd, contentLength: contentLength, from: connection)
                // A streaming route (e.g. /stream) takes ownership of the socket
                // and keeps it open — don't cancel it here.
                if self.handedOff.contains(ObjectIdentifier(connection)) { return }
                if isComplete || error != nil { connection.cancel() }
            }
        }
    }

    // MARK: - HTTP Parsing

    private enum RequestState {
        case incomplete
        case complete(headerEnd: Int, contentLength: Int)
    }

    /// Determine whether `acc` holds a complete HTTP request. Operates on raw
    /// bytes (binary-safe) and honors Content-Length.
    private static func requestState(of acc: Data) -> RequestState {
        // Find the CRLFCRLF header/body separator.
        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let r = acc.range(of: sep) else { return .incomplete }
        let headerEnd = r.upperBound
        // Parse Content-Length from the header block (case-insensitive).
        let headerData = acc.subdata(in: acc.startIndex..<r.lowerBound)
        let headerStr = String(data: headerData, encoding: .utf8) ?? ""
        var contentLength = 0
        for line in headerStr.components(separatedBy: "\r\n") {
            let p = line.split(separator: ":", maxSplits: 1)
            if p.count == 2, p[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(p[1].trimmingCharacters(in: .whitespaces)) ?? 0
                break
            }
        }
        let haveBody = acc.count - headerEnd
        return haveBody >= contentLength ? .complete(headerEnd: headerEnd, contentLength: contentLength)
                                         : .incomplete
    }

    private func processHTTPRequest(_ data: Data, headerEnd: Int, contentLength: Int, from connection: NWConnection) {
        let headerData = data.subdata(in: data.startIndex..<headerEnd)
        guard let raw = String(data: headerData, encoding: .utf8) else {
            sendHTTPResponse(connection: connection, status: 400, body: "Bad Request")
            return
        }

        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendHTTPResponse(connection: connection, status: 400, body: "Bad Request")
            return
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            sendHTTPResponse(connection: connection, status: 400, body: "Bad Request")
            return
        }

        let method = String(parts[0])
        let path = String(parts[1])

        // Parse headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            let headerParts = line.split(separator: ":", maxSplits: 1)
            if headerParts.count == 2 {
                headers[String(headerParts[0]).trimmingCharacters(in: .whitespaces).lowercased()] =
                    String(headerParts[1]).trimmingCharacters(in: .whitespaces)
            }
        }

        // Extract the body as raw bytes (exactly Content-Length), binary-safe.
        var body: Data?
        if contentLength > 0 {
            let end = min(data.count, headerEnd + contentLength)
            body = data.subdata(in: headerEnd..<end)
        }

        route(method: method, path: path, headers: headers, body: body, connection: connection)
    }

    // MARK: - Routing

    private func route(method: String, path: String, headers: [String: String], body: Data?, connection: NWConnection) {
        // Split off any query string so path matching is exact.
        let rawPath = path
        let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let query = rawPath.contains("?") ? String(rawPath.split(separator: "?", maxSplits: 1).dropFirst().first ?? "") : ""

        switch (method, pathOnly) {
        case ("GET", "/"):
            handleDocPage(connection: connection, headers: headers)

        case ("GET", "/schema"):
            handleSchema(connection: connection)

        // Which device this is, before any key is chosen: clients store one
        // key per device and look it up by this id.
        case ("GET", "/whoami"):
            // Only what a client needs to pick its key: the name and anything
            // else about the device stay behind authentication (device_info).
            let info: [String: Any] = [
                "device_id": NearbyIdentity.deviceID,
                "protocol_version": RPCMethodRegistry.protocolVersion,
                "server_version": RPCMethodRegistry.serverVersion,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])) ?? Data("{}".utf8)
            // Same-origin only: any web page the phone (or a LAN browser)
            // opens could otherwise read the device id and name.
            sendHTTPResponse(connection: connection, status: 200, contentType: "application/json",
                             body: String(data: data, encoding: .utf8) ?? "{}", cors: false)

        case ("GET", "/skill"), ("GET", "/skill.md"), ("GET", "/SKILL.md"):
            handleSkill(connection: connection)

        // Bootstrap: a working client, downloadable off the device itself, so a
        // caller that doesn't yet speak the v1 envelope can fetch one and start
        // immediately. Unauthenticated on purpose — it serves example code only,
        // never session data, and the protocol it implements is public anyway.
        // /skill/examples/* are kept as aliases: an installed copy of the manual
        // may still name them, and a 404 there would look like a broken build.
        case ("GET", "/skill/clients/python"), ("GET", "/skill/clients/ictrl_rpc.py"),
             ("GET", "/skill/examples/python"), ("GET", "/skill/examples/ictrl_rpc.py"),
             ("GET", "/client.py"):
            handleClientSource(connection: connection)

        // The compiled client, for sandboxes with no Python. Static
        // aarch64-musl, so it runs in the Minis Alpine guest with no install
        // step — which matters there because that rootfs ships no interpreter.
        case ("GET", "/skill/clients/cli"), ("GET", "/skill/clients/ictrl"),
             ("GET", "/skill/examples/cli"), ("GET", "/skill/examples/ictrl"),
             ("GET", "/ictrl"):
            handleClientBinary(connection: connection)

        case ("GET", "/skill/clients/cli.sh"), ("GET", "/skill/clients/ictrl.sh"),
             ("GET", "/skill/examples/cli.sh"), ("GET", "/skill/examples/ictrl.sh"):
            handleClientWrapper(connection: connection)

        case ("GET", "/docs"):
            handleDocsPage(connection: connection)

        case ("GET", "/stream"), ("GET", "/stream.ts"):
            handleVideoStream(headers: headers, query: query, connection: connection)

        case ("GET", "/remote"):
            // The page itself is unauthenticated (it needs to load so the user can
            // paste a token). The RPC + stream calls it makes are authenticated.
            // Revalidated on every load: the page ships inside the runner, and a
            // Home Screen web app would otherwise keep an older copy after an update.
            sendHTTPResponse(connection: connection, status: 200,
                             headers: ["Cache-Control": "no-cache"],
                             contentType: "text/html; charset=utf-8", body: RemoteHTML.page)

        // What a Home Screen web app made from /remote needs: its manifest
        // (which opens it full screen) and its icon. Unauthenticated, like the page.
        case ("GET", "/remote/manifest.webmanifest"):
            sendHTTPResponse(connection: connection, status: 200,
                             contentType: "application/manifest+json", body: RemoteHTML.manifest)

        case ("GET", "/remote/icon.png"):
            sendHTTPData(connection: connection, status: 200,
                         headers: ["Cache-Control": "max-age=86400"],
                         contentType: "image/png", body: RemoteIcon.png)

        // Logs can carry sensitive context even redacted. They are GETs that a
        // browser issues directly, so they can't carry an envelope body — they
        // use the same single-use ticket as /stream, minted over the encrypted
        // channel via the `stream_ticket` RPC.
        case ("GET", "/logs/files"):
            guard hasValidTicket(query) else { return sendUnauthorizedHTTP(connection) }
            handleLogFiles(connection: connection)

        case ("GET", "/logs/history"):
            guard hasValidTicket(query) else { return sendUnauthorizedHTTP(connection) }
            handleLogHistory(connection: connection, query: query)

        case ("GET", "/logs"):
            guard hasValidTicket(query) else { return sendUnauthorizedHTTP(connection) }
            handleLogs(connection: connection)

        case ("POST", "/pair"):
            handlePair(body: body, connection: connection, isLoopback: isLoopback(connection),
                       nearby: isNearby(connection))

        case ("POST", "/rpc"):
            handleRPC(headers: headers, body: body, connection: connection)

        case ("OPTIONS", _):
            sendHTTPResponse(connection: connection, status: 200, headers: corsHeaders(), body: "")

        default:
            sendHTTPResponse(connection: connection, status: 404, body: "Not Found")
        }
    }

    // MARK: - Handlers

    /// GET / — content-negotiated:
    ///   Accept: application/json  → the JSON schema (machine-readable methods)
    ///   Accept: text/html         → the visual HTML docs page (for browsers)
    ///   default (agents/curl)     → the SKILL.md operating manual (Markdown)
    /// The HTML page is also always at /docs.
    private func handleDocPage(connection: NWConnection, headers: [String: String]) {
        let accept = headers["accept"] ?? ""
        if accept.contains("application/json") {
            let schema = RPCMethodRegistry.generateSchemaDocument()
            if let jsonData = try? JSONSerialization.data(withJSONObject: schema, options: .prettyPrinted),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                sendHTTPResponse(connection: connection, status: 200, contentType: "application/json", body: jsonString)
            } else {
                sendHTTPResponse(connection: connection, status: 500, body: "Failed to generate schema")
            }
        } else if accept.contains("text/html") {
            // A real browser asked — give it the visual page.
            handleDocsPage(connection: connection)
        } else {
            // Default (agents, curl): the Skill manual — read once, drive the phone.
            handleSkill(connection: connection)
        }
    }

    private func handleDocsPage(connection: NWConnection) {
        let html = RPCMethodRegistry.generateHTMLDoc()
        sendHTTPResponse(connection: connection, status: 200, contentType: "text/html; charset=utf-8", body: html)
    }

    private func handleSchema(connection: NWConnection) {
        let schema = RPCMethodRegistry.generateSchemaDocument()
        if let jsonData = try? JSONSerialization.data(withJSONObject: schema, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            sendHTTPResponse(connection: connection, status: 200, contentType: "application/json", body: jsonString)
        } else {
            sendHTTPResponse(connection: connection, status: 500, body: "Failed to generate schema")
        }
    }

    /// GET /skill — the operating manual in Skill (Markdown + frontmatter) format,
    /// so an agent can read it once and treat iCTRL as a Skill. Served from the
    /// bundled SKILL.md resource; falls back to a pointer if the resource is
    /// missing. The dynamic method list stays at /schema.
    /// GET /skill/clients/python — the reference client's source.
    ///
    /// Serving it from the device guarantees the client always matches the
    /// running build's protocol. Plain text so `curl … > ictrl_rpc.py` just works.
    private func handleClientSource(connection: NWConnection) {
        guard let src = Self.bundledResource(named: "ictrl_rpc", ext: "py") else {
            sendHTTPResponse(connection: connection, status: 404,
                             body: "Reference client not bundled in this build. "
                                 + "The protocol is fully specified in GET /skill.")
            return
        }
        sendHTTPResponse(connection: connection, status: 200,
                         contentType: "text/x-python; charset=utf-8", body: src)
    }

    private func handleSkill(connection: NWConnection) {
        let md = Self.bundledSkillMarkdown()
            ?? "# iCTRL\n\nOperating manual resource missing. Fetch GET /schema for the machine-readable method list and guidance.\n"
        sendHTTPResponse(connection: connection, status: 200,
                         contentType: "text/markdown; charset=utf-8", body: md)
    }

    /// GET /skill/clients/cli — the static CLI binary.
    ///
    /// Served as an octet-stream off the device so a caller can fetch a working
    /// client without a toolchain or a package manager. Same rationale as the
    /// Python endpoint: the binary always matches this build's protocol.
    private func handleClientBinary(connection: NWConnection) {
        guard let data = Self.bundledResourceData(named: "ictrl", ext: nil) else {
            sendHTTPResponse(connection: connection, status: 404,
                             body: "CLI binary not bundled in this build. "
                                 + "Use GET /skill/clients/python, or build it from cli/ in the repo.")
            return
        }
        sendHTTPData(connection: connection, status: 200,
                     headers: ["Content-Disposition": "attachment; filename=\"ictrl\""],
                     contentType: "application/octet-stream", body: data)
    }

    /// GET /skill/clients/cli.sh — the wrapper that chmods the binary.
    ///
    /// Needed because a skill installer may write files without the exec bit;
    /// the wrapper runs via `sh`, which does not need one, and fixes the mode.
    private func handleClientWrapper(connection: NWConnection) {
        guard let src = Self.bundledResource(named: "ictrl", ext: "sh") else {
            sendHTTPResponse(connection: connection, status: 404,
                             body: "CLI wrapper not bundled in this build.")
            return
        }
        sendHTTPResponse(connection: connection, status: 200,
                         contentType: "text/plain; charset=utf-8", body: src)
    }

    /// Raw bytes of a bundled resource (the String variant would corrupt a binary).
    static func bundledResourceData(named name: String, ext: String?) -> Data? {
        let candidates = [Bundle(for: JSONRPCServer.self), Bundle.main] + Bundle.allBundles
        for b in candidates {
            if let url = b.url(forResource: name, withExtension: ext),
               let d = try? Data(contentsOf: url) {
                return d
            }
        }
        return nil
    }

    /// Load SKILL.md from whichever bundle carries it. The resource ships inside
    /// the UITests .xctest bundle (this class's bundle), not runner.app's root, so
    /// try Bundle(for:) first, then main + all loaded bundles as a fallback.
    static func bundledSkillMarkdown() -> String? {
        guard let raw = bundledResource(named: "SKILL", ext: "md") else { return nil }
        return stampSkillVersion(raw)
    }

    /// Rewrite the frontmatter's `skill_version` to the running build's version.
    ///
    /// The whole point of the version is to let an installed copy notice it has
    /// gone stale, which fails the moment the number in the file disagrees with
    /// what device_info reports. Stamping it at serve time makes drift
    /// impossible: there is one source of truth (`RPCMethod.serverVersion`) and
    /// the checked-in literal is only a placeholder.
    static func stampSkillVersion(_ markdown: String) -> String {
        let version = RPCMethodRegistry.serverVersion
        var lines = markdown.components(separatedBy: "\n")
        // Only touch the frontmatter block: a `skill_version:` line in prose (an
        // example, say) must not be rewritten.
        guard lines.first == "---",
              let end = lines.dropFirst().firstIndex(of: "---") else { return markdown }
        for i in 1..<end where lines[i].hasPrefix("skill_version:") {
            lines[i] = "skill_version: \"\(version)\""
            return lines.joined(separator: "\n")
        }
        // No declaration yet — insert one so older checked-in copies still serve
        // a version rather than silently omitting it.
        lines.insert("skill_version: \"\(version)\"", at: end)
        return lines.joined(separator: "\n")
    }

    /// Read a file bundled with the runner. Used to serve the operating manual
    /// and the reference clients straight off the device, so a caller can
    /// bootstrap the encrypted protocol with one unauthenticated GET.
    static func bundledResource(named name: String, ext: String) -> String? {
        let candidates = [Bundle(for: JSONRPCServer.self), Bundle.main] + Bundle.allBundles
        for b in candidates {
            if let url = b.url(forResource: name, withExtension: ext),
               let s = try? String(contentsOf: url, encoding: .utf8) {
                return s
            }
        }
        return nil
    }

    private func handleLogs(connection: NWConnection) {
        // Auth-required (checked in route()). Content is still redacted as defense in depth.
        let logs = onLogsRequest?() ?? "(no logs available)"
        let header = "# iCTRL logs (redacted — sensitive values masked)\n\n"
        sendHTTPResponse(connection: connection, status: 200, contentType: "text/plain; charset=utf-8", body: header + logs)
    }

    /// GET /logs/files — list persisted daily log files (survive crashes/restarts).
    private func handleLogFiles(connection: NWConnection) {
        let listing = onLogFilesRequest?() ?? "(no log files)"
        let header = "# iCTRL persisted log files\n# GET /logs/history?date=YYYY-MM-DD to read one\n\n"
        sendHTTPResponse(connection: connection, status: 200, contentType: "text/plain; charset=utf-8", body: header + listing)
    }

    /// GET /logs/history?date=YYYY-MM-DD — dump a persisted day's log (redacted).
    /// This is how you recover the log from BEFORE a crash/restart, since /logs
    /// only holds the current process's in-memory buffer.
    private func handleLogHistory(connection: NWConnection, query: String) {
        // Parse date=... from the query string.
        var date: String? = nil
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "date" {
                date = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
        }
        let content = onLogHistoryRequest?(date) ?? "(no history log available)"
        let header = "# iCTRL persisted log (redacted)\(date.map { " — \($0)" } ?? " — today")\n\n"
        sendHTTPResponse(connection: connection, status: 200, contentType: "text/plain; charset=utf-8", body: header + content)
    }

    /// POST /pair — grant a 32-byte token key K after on-device approval.
    ///
    /// Two modes, mirroring MinisApp's debug server:
    ///   - `{"client_name":"…","plain":true}` returns K in the clear. Accepted
    ///     ONLY from 127.0.0.1 (USB/iproxy), since anyone who sees the response
    ///     owns the device.
    ///   - `{"client_name":"…","pub":"<base64 raw 32B X25519>"}` wraps K against
    ///     an ephemeral device key, so it is safe over the LAN.
    ///
    /// Blocks until the user taps Allow (or the alert times out).
    private func handlePair(body: Data?, connection: NWConnection, isLoopback: Bool, nearby: Bool) {
        guard let body = body,
              let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let clientName = obj["client_name"] as? String, !clientName.isEmpty else {
            sendPairError(connection, status: 400, code: "bad_request",
                          message: "client_name is required")
            return
        }

        let isPlain = obj["plain"] as? Bool ?? false
        var clientPub: Data?
        if !isPlain {
            guard let pubB64 = obj["pub"] as? String,
                  let pub = Data(base64Encoded: pubB64), pub.count == 32 else {
                sendPairError(connection, status: 400, code: "bad_request",
                              message: "Provide plain:true (loopback only) or pub (base64 raw 32B X25519)")
                return
            }
            clientPub = pub
        }
        if isPlain && !isLoopback {
            sendPairError(connection, status: 403, code: "plain_forbidden",
                          message: "Plain grant is localhost/USB only; use X25519 mode")
            return
        }

        // Shown on the prompt and printed by the client, so a request from an
        // impostor on the network can be told apart from the user's own.
        let fingerprint = clientPub.map { Data(SHA256.hash(data: $0).prefix(4)).hexString }
        AuthManager.shared.requestAuth(clientName: clientName, nearby: nearby, local: isLoopback,
                                       fingerprint: fingerprint) { [weak self] outcome in
            guard let self = self else { return }
            let session: AuthSession
            switch outcome {
            case .approved(let s):
                session = s
                AuthManager.shared.recordPeer(sessionID: s.id, peer: Self.peer(of: connection))
            case .denied:
                self.sendPairError(connection, status: 403, code: "pair_denied",
                                   message: "User rejected or approval timed out")
                return
            case .busy(let retryAfter):
                self.sendPairError(connection, status: 429, code: "pair_busy",
                                   message: "Another pairing request is waiting for approval on the device",
                                   retryAfter: retryAfter)
                return
            case .coolingDown(let retryAfter):
                self.sendPairError(connection, status: 429, code: "pair_cooldown",
                                   message: "A pairing request was just refused; try again in \(retryAfter)s",
                                   retryAfter: retryAfter)
                return
            }
            guard let key = session.key else {
                self.sendPairError(connection, status: 500, code: "internal",
                                   message: "Session has no key")
                return
            }

            // Informational only: real expiry slides forward on every use.
            let expires = Int(session.expiresAt.timeIntervalSince1970)
            var response: [String: Any] = [
                "tok": session.id,
                "client_name": session.clientName,
                "expires": expires,
            ]

            if let clientPub = clientPub {
                do {
                    let devicePriv = Curve25519.KeyAgreement.PrivateKey()
                    let devicePub = devicePriv.publicKey.rawRepresentation
                    let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientPub)
                    let shared = try devicePriv.sharedSecretFromKeyAgreement(with: peer)
                    let sharedData = shared.withUnsafeBytes { Data($0) }
                    let kWrap = SecureEnvelope.hmac(
                        sharedData,
                        Data(SecureEnvelope.labelPair.utf8) + clientPub + devicePub)
                    let pad = SecureEnvelope.hmac(kWrap, Data(SecureEnvelope.labelWrap.utf8))
                    response["pub"] = devicePub.base64EncodedString()
                    response["token_ct"] = Data(zip(key, pad).map { $0 ^ $1 }).hexString
                } catch {
                    AuthManager.shared.revokeSession(id: session.id)
                    self.sendPairError(connection, status: 400, code: "bad_request",
                                       message: "X25519 key agreement failed")
                    return
                }
            } else {
                response["token"] = key.hexString
            }

            if let data = try? JSONSerialization.data(withJSONObject: response, options: .prettyPrinted),
               let json = String(data: data, encoding: .utf8) {
                self.sendHTTPResponse(connection: connection, status: 200,
                                      contentType: "application/json", body: json)
            }
        }
    }

    private func sendPairError(_ connection: NWConnection, status: Int, code: String, message: String,
                               retryAfter: Int? = nil) {
        var error: [String: Any] = ["code": code, "message": message,
                                    "server_ts": Int(Date().timeIntervalSince1970)]
        var headers: [String: String] = [:]
        if let retryAfter {
            error["retry_after"] = retryAfter
            headers["Retry-After"] = String(retryAfter)
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["error": error])) ?? Data("{}".utf8)
        sendHTTPResponse(connection: connection, status: status, headers: headers,
                         contentType: "application/json",
                         body: String(data: data, encoding: .utf8) ?? "{}")
    }

    /// GET /stream[.ts]?ticket=… — live H.264-in-MPEG-TS screen video.
    ///
    /// `<video src>` can't sign its own request, so this is the one endpoint not
    /// protected by an envelope. Instead it takes a single-use ticket minted over
    /// the encrypted channel (`stream_ticket` RPC): short-lived, consumed on
    /// first use, and useless to anyone who scrapes the URL afterwards.
    /// Optional ?fps=N (0.5–30, default 5; what capture sustains depends on
    /// the capture path and the device's temperature — see VideoBroadcaster).
    /// Hands the connection to the host's
    /// video streamer (kept open until the client disconnects).
    private func handleVideoStream(headers: [String: String], query: String, connection: NWConnection) {
        guard hasValidTicket(query) else {
            sendHTTPResponse(connection: connection, status: 401,
                             body: "Unauthorized: GET /stream needs ?ticket=<t>. "
                                 + "Mint one with the stream_ticket RPC over the encrypted channel.")
            return
        }
        guard let handoff = onVideoStream else {
            sendHTTPResponse(connection: connection, status: 503, body: "Video streaming unavailable")
            return
        }
        var fps = 5.0
        var quality = "auto"
        var verbose = false
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "fps":     if let v = Double(kv[1]) { fps = v }
            case "quality": quality = String(kv[1])
            case "verbose": verbose = (kv[1] == "1" || kv[1] == "true")
            default: break
            }
        }
        handedOff.insert(ObjectIdentifier(connection))
        handoff(connection, fps, quality, verbose)
    }

    /// True if the query carries a valid single-use `ticket=`.
    ///
    /// Browser-issued GETs (`<video src>`, log links) can't carry an encrypted
    /// envelope, so they present a ticket instead — minted over the encrypted
    /// channel by the `stream_ticket` RPC, valid ~60s, and consumed on first use.
    /// No long-lived secret ever appears in a URL.
    private func hasValidTicket(_ query: String) -> Bool {
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "ticket",
               let ticket = String(kv[1]).removingPercentEncoding,
               AuthManager.shared.consumeStreamTicket(ticket) {
                return true
            }
        }
        return false
    }

    /// Whether the peer is 127.0.0.1/::1 — the only source allowed to request a
    /// plaintext key grant at pairing time.
    /// Deliberately built only from `NWConnection.endpoint` and raw address
    /// bytes — all iOS 12-era API.
    ///
    /// The obvious spelling (`connection.currentPath?.remoteEndpoint`, then
    /// `IPv4Address.isLoopback`) reads better but is a trap: those are
    /// Swift-only properties added later, and on an OS that lacks them the
    /// symbol is missing at LOAD time. The runner then dies before a single
    /// line of our code runs, with no crash report pointing anywhere near
    /// here — which is exactly how this cost days to find. Prefer the older,
    /// duller API in code that must load on the oldest supported OS.
    private func isLoopback(_ connection: NWConnection) -> Bool {
        guard case let .hostPort(host, _) = connection.endpoint else { return false }
        switch host {
        case .ipv4(let addr):
            return addr.rawValue.first == 127          // 127.0.0.0/8
        case .ipv6(let addr):
            let b = [UInt8](addr.rawValue)
            guard b.count == 16 else { return false }
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }   // ::1
            // ::ffff:127.x.x.x (IPv4-mapped)
            let v4Mapped = b[0..<10].allSatisfy { $0 == 0 } && b[10] == 0xff && b[11] == 0xff
            return v4Mapped && b[12] == 127
        @unknown default:
            return false
        }
    }

    /// Plain-text 401 for non-RPC (e.g. GET /logs) endpoints.
    private func sendUnauthorizedHTTP(_ connection: NWConnection) {
        sendHTTPResponse(connection: connection, status: 401,
                         body: "Unauthorized: append ?ticket=<t> (mint one with the stream_ticket RPC over the encrypted channel).")
    }

    private func handleRPC(headers: [String: String], body: Data?, connection: NWConnection) {
        // Every /rpc call must arrive as a sealed v1 envelope. There is no
        // plaintext path: an unsealed body is rejected before it is even parsed
        // as JSON-RPC, so an unauthenticated caller learns nothing about the
        // method surface.
        guard let body = body,
              let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            sendAuthError(connection, status: 400, code: "bad_envelope",
                          message: "Body must be a v1 encrypted envelope")
            return
        }
        guard SecureEnvelope.looksLikeEnvelope(obj) else {
            sendAuthError(connection, status: 401, code: "auth_required",
                          message: "Encrypted envelope required. POST /pair to obtain a key, "
                                 + "then wrap each JSON-RPC body per the v1 protocol (see /skill).")
            return
        }

        let opened: (tokId: String, plaintext: String, seal: (String) -> String)
        do {
            opened = try AuthManager.shared.openEnvelope(obj, peer: Self.peer(of: connection))
        } catch let failure as SecureEnvelope.Failure {
            // 401 for anything token/auth related so clients know to re-pair;
            // 400 only for a structurally broken envelope.
            let status = failure.code == "bad_envelope" ? 400 : 401
            sendAuthError(connection, status: status, code: failure.code, message: failure.message)
            return
        } catch {
            sendAuthError(connection, status: 401, code: "auth_failed", message: "Authentication failed — this key is not usable. Re-pair to continue: POST /pair (the device user must tap Allow). Note a key is dropped after 30 days with no successful call, so a long-idle client must re-pair. If instead the clock is off you would get ts_skew, not this.")
            return
        }

        let seal = opened.seal
        guard let inner = opened.plaintext.data(using: .utf8),
              let rpcRequest = try? JSONDecoder().decode(JSONRPCRequest.self, from: inner) else {
            sendSealed(connection, seal: seal, json: Self.errorJSON(nil, .parseError))
            return
        }
        guard rpcRequest.jsonrpc == "2.0" else {
            sendSealed(connection, seal: seal, json: Self.errorJSON(rpcRequest.id, .invalidRequest))
            return
        }

        // `stream_ticket` is served here rather than in the action handler: it
        // mints credentials, so it must stay inside the authenticated boundary
        // and needs the token id this envelope authenticated as.
        if rpcRequest.method == "stream_ticket" {
            // Use the identity the envelope actually AUTHENTICATED as — never
            // re-read obj["tok"], which is unverified input.
            guard let issued = AuthManager.shared.issueStreamTicket(forTokenId: opened.tokId) else {
                sendSealed(connection, seal: seal,
                           json: Self.errorJSON(rpcRequest.id, .internalError))
                return
            }
            let result: [String: JSONValue] = [
                "ticket": .string(issued.ticket),
                "expires_in": .int(issued.expiresIn),
                "hint": .string("Append ?ticket=<ticket> to GET /stream or /logs. "
                              + "Single use, expires in \(issued.expiresIn)s."),
            ]
            sendSealed(connection, seal: seal, json: Self.resultJSON(rpcRequest.id, result))
            return
        }

        guard let handler = onRPCRequest else {
            sendSealed(connection, seal: seal, json: Self.errorJSON(rpcRequest.id, .internalError))
            return
        }

        let method = rpcRequest.method
        var params = rpcRequest.params
        // `config` may widen who can reach the device (nearby discovery), which
        // only a caller on this device may do. Tell it where this request came
        // from; set here, after authentication, and overwriting any value the
        // caller sent, so it cannot be claimed.
        if method == "config" {
            var p = params ?? [:]
            p[Self.peerSourceParam] = .string(Self.peer(of: connection)?.via ?? PeerSource.other.rawValue)
            params = p
        }
        handler(method, params) { [weak self] result, error in
            let json = error.map { Self.errorJSON(rpcRequest.id, $0) }
                ?? Self.resultJSON(rpcRequest.id, result ?? [:])
            self?.sendSealed(connection, seal: seal, json: json)
            // Latency shortcut: when a UI-mutating RPC finishes, tell the video
            // pipeline to grab an extra keyframe *now* instead of waiting for
            // the next 1/fps tick. Without this, a 2 fps tap can wait up to
            // ~500 ms before the user sees the reaction.
            if Self.uiMutatingMethods.contains(method) {
                self?.onRPCUIChanged?()
            }
        }
    }

    /// Encrypt a JSON-RPC reply into a response envelope and write it out.
    /// Always HTTP 200: transport succeeded, and the real status is inside the
    /// sealed body (an eavesdropper shouldn't learn outcomes from status codes).
    private func sendSealed(_ connection: NWConnection, seal: (String) -> String, json: String) {
        sendHTTPResponse(connection: connection, status: 200,
                         contentType: "application/json", body: seal(json))
    }

    /// Auth failures are sent in the CLEAR — the client has no usable key yet
    /// (or the one it used was rejected), so a sealed reply would be unreadable.
    private func sendAuthError(_ connection: NWConnection, status: Int, code: String, message: String) {
        let payload: [String: Any] = [
            "error": ["code": code, "message": message,
                      "server_ts": Int(Date().timeIntervalSince1970)],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        sendHTTPResponse(connection: connection, status: status, contentType: "application/json",
                         body: String(data: data, encoding: .utf8) ?? "{}")
    }

    private static func resultJSON(_ id: JSONValue?, _ result: [String: JSONValue]) -> String {
        encode(JSONRPCResponse(result: result, error: nil, id: id))
    }

    private static func errorJSON(_ id: JSONValue?, _ error: JSONRPCError) -> String {
        encode(JSONRPCResponse(result: nil, error: error, id: id))
    }

    private static func encode(_ response: JSONRPCResponse) -> String {
        guard let data = try? JSONEncoder().encode(response),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"jsonrpc":"2.0","error":{"code":-32603,"message":"Internal error"},"id":null}"#
        }
        return json
    }

    /// RPCs that visibly change what's on screen — used to trigger an out-of-
    /// band keyframe on the video stream so the browser reflects the change
    /// with sub-500 ms delay instead of waiting for the next capture tick.
    private static let uiMutatingMethods: Set<String> = [
        "tap", "double_tap", "long_press", "swipe", "drag_up", "drag_down",
        "drag_move", "scroll", "scroll_to_element", "tap_element", "find_and_tap", "page", "collect",
        "type", "clear_text", "home", "lock", "unlock",
        "launch_app", "activate_app", "terminate_app", "open_url",
    ]

    // MARK: - Response Helpers

    private func sendJSONRPCResult(_ id: JSONValue?, result: [String: JSONValue], connection: NWConnection) {
        let response = JSONRPCResponse(result: result, error: nil, id: id)
        if let data = try? JSONEncoder().encode(response), let str = String(data: data, encoding: .utf8) {
            sendHTTPResponse(connection: connection, status: 200, contentType: "application/json", body: str)
        }
    }

    private func sendJSONRPCError(_ id: JSONValue?, error: JSONRPCError, connection: NWConnection) {
        let response = JSONRPCResponse(result: nil, error: error, id: id)
        // Only a genuine auth failure maps to HTTP 401. Every other JSON-RPC error
        // (business/timeout/-32000, parse, invalid params, …) is a processed
        // request whose failure travels in the JSON body, so HTTP stays 200 — else
        // a slow/timed-out action reads as "unauthorized" to clients.
        let statusCode = error.code == JSONRPCError.unauthorizedCode ? 401 : 200
        if let data = try? JSONEncoder().encode(response), let str = String(data: data, encoding: .utf8) {
            sendHTTPResponse(connection: connection, status: statusCode, contentType: "application/json", body: str)
        }
    }

    /// Headers on every response. `X-ICTRL-Device` names the device behind
    /// this address, so a client can keep one key per device across USB, LAN
    /// and nearby, and notice when a different device now answers at an
    /// address it knows. The id is random per installation and is already
    /// advertised to nearby devices.
    private func corsHeaders() -> [String: String] {
        [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": Self.corsAllowHeaders,
            // Not listed in Access-Control-Expose-Headers: a web page must not
            // be able to read a stable device id cross-origin. Clients that
            // need it are not browsers.
            Self.deviceHeader: NearbyIdentity.deviceID,
        ]
    }

    static let deviceHeader = "X-ICTRL-Device"
    private static let corsAllowHeaders = "Content-Type, Authorization"
    /// Parameter the server adds to `config`: the request's `PeerSource`.
    static let peerSourceParam = "_peer_source"

    /// Send a response whose body is raw bytes.
    ///
    /// The String-based sender round-trips through UTF-8, which silently
    /// mangles a binary — a downloaded executable would arrive corrupt.
    private func sendHTTPData(connection: NWConnection, status: Int,
                              headers: [String: String] = [:],
                              contentType: String, body: Data) {
        var allHeaders = corsHeaders()
        allHeaders["Content-Type"] = contentType
        allHeaders["Content-Length"] = "\(body.count)"
        allHeaders["Connection"] = "close"
        for (k, v) in headers { allHeaders[k] = v }

        let headerString = allHeaders.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
        var responseData = "HTTP/1.1 \(status) OK\r\n\(headerString)\r\n\r\n".data(using: .utf8) ?? Data()
        responseData.append(body)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendHTTPResponse(connection: NWConnection, status: Int, headers: [String: String] = [:],
                                  contentType: String = "text/plain", body: String, cors: Bool = true) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        case 429: statusText = "Too Many Requests"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        let bodyData = body.data(using: .utf8) ?? Data()

        var allHeaders = corsHeaders()
        if !cors {
            for key in ["Access-Control-Allow-Origin", "Access-Control-Allow-Methods", "Access-Control-Allow-Headers"] {
                allHeaders.removeValue(forKey: key)
            }
        }
        allHeaders["Content-Type"] = contentType
        allHeaders["Content-Length"] = "\(bodyData.count)"
        allHeaders["Connection"] = "close"
        for (k, v) in headers {
            allHeaders[k] = v
        }

        let headerString = allHeaders.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
        let responseString = "HTTP/1.1 \(status) \(statusText)\r\n\(headerString)\r\n\r\n"

        var responseData = responseString.data(using: .utf8) ?? Data()
        responseData.append(bodyData)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func removeConnection(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
        nearbyConnections.remove(ObjectIdentifier(connection))
    }

    deinit {
        stop()
    }
}
