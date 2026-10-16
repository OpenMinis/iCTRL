import Foundation

/// State behind the runner's client list and live log, shared by both screens.
///
/// Everything comes from the runner over `RunnerClient`: `config` lists and
/// revokes sessions, `logs` returns the recent log. Errors are kept as a short
/// user-facing notice instead of being thrown at the views.
@MainActor
final class RunnerAdmin: ObservableObject {
    struct Client: Identifiable, Equatable {
        let id: String
        let name: String
        let grantedAt: Date?
        let lastActiveAt: Date?
        /// Where its last request came from; nil before it was recorded.
        let lastAddress: String?
        /// `PeerSource` raw value: local, lan, nearby, vpn, cellular, other.
        let lastVia: String?
    }

    @Published private(set) var isPaired: Bool
    @Published private(set) var pairing = false
    /// Why the last operation failed, in the user's language; nil when fine.
    @Published private(set) var notice: String?
    @Published private(set) var clients: [Client] = []
    /// Who can reach the runner right now, from its `config`; nil until known.
    @Published private(set) var visibility: Visibility?
    /// Nearby discovery is switched on but not advertising yet (waiting for
    /// Wi-Fi or permission): `visibility` says what was chosen, this says it
    /// is not in effect.
    @Published private(set) var nearbyPending = false
    /// The runner reported that iOS refused it Local Network access.
    @Published private(set) var localNetworkDenied = false

    /// The runner's reach, widest first. Only local is safe from other devices.
    enum Visibility: Hashable {
        /// Loopback only: apps on this device and a computer over USB.
        case local
        /// Remote access on: anyone on the same network can try to pair.
        case lan
        /// Remote access on and advertised over AWDL to nearby Apple devices.
        case lanAndNearby
    }
    @Published private(set) var clientsLoaded = false
    @Published private(set) var logLines: [String] = []
    @Published private(set) var logsLoaded = false

    private let client: RunnerClient
    /// The runner keeps 500 lines at most per `logs` call.
    static let logLineLimit = 500

    init(port: Int) {
        client = RunnerClient(port: port)
        isPaired = client.isPaired
    }

    var ownSessionID: String? { client.sessionID }
    var otherClients: [Client] { clients.filter { $0.id != ownSessionID } }

    // MARK: - Pairing

    func connect() async {
        guard !pairing else { return }
        pairing = true
        notice = nil
        defer { pairing = false }
        do {
            try await client.pair()
            isPaired = true
            ictrlLog("Runner admin: paired as \(client.sessionID ?? "?")")
            await loadClients()
        } catch {
            handle(error)
        }
    }

    // MARK: - Clients

    func loadClients() async {
        guard client.isPaired else { isPaired = false; return }
        do {
            let result = try await client.call("config")
            clients = Self.parseClients(result["sessions"])
            visibility = Self.parseVisibility(result)
            let nearby = result["nearby"] as? [String: Any]
            nearbyPending = (nearby?["enabled"] as? Bool) == true && (nearby?["advertising"] as? Bool) != true
            localNetworkDenied = (result["nearby"] as? [String: Any])?["local_network"] as? String == "denied"
            clientsLoaded = true
            notice = nil
        } catch {
            handle(error)
        }
    }

    func revoke(_ id: String) async {
        do {
            let result = try await client.call("config", ["revoke_session_id": id])
            clients = Self.parseClients(result["sessions"])
            visibility = Self.parseVisibility(result)
            ictrlLog("Runner admin: revoked session \(id)")
        } catch {
            handle(error)
        }
    }

    /// Revoke every client except this app, one by one: the runner's
    /// `clear_sessions` would cut this app off too.
    func revokeOthers() async {
        for other in otherClients {
            await revoke(other.id)
            if !isPaired { return }
        }
    }

    /// Revoke this app's own key on the runner, then forget it here.
    func disconnect() async {
        if let own = ownSessionID {
            _ = try? await client.call("config", ["revoke_session_id": own])
        }
        client.forget()
        isPaired = false
        clients = []
        clientsLoaded = false
        visibility = nil
        logLines = []
        logsLoaded = false
        ictrlLog("Runner admin: disconnected")
    }

    // MARK: - Visibility

    @Published private(set) var changingVisibility = false

    /// Set who can reach the runner. Turning remote access on or off restarts
    /// the runner's listener, so the reply can be lost; the state is read back
    /// afterwards either way.
    func setVisibility(_ target: Visibility) async {
        guard target != visibility, !changingVisibility else { return }
        changingVisibility = true
        defer { changingVisibility = false }
        var params: [String: Any]
        switch target {
        case .local: params = ["allow_remote_access": false]
        case .lan: params = ["allow_remote_access": true, "nearby_discovery": false]
        case .lanAndNearby: params = ["allow_remote_access": true, "nearby_discovery": true]
        }
        do {
            _ = try await client.call("config", params)
            ictrlLog("Runner admin: visibility -> \(target)")
        } catch RunnerClient.Failure.notRunning {
            // The listener restarting under the reply; checked below.
        } catch {
            handle(error)
        }
        // Nearby confirms its advertisement a moment after it is switched on.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await loadClients()
    }

    // MARK: - Stop

    /// Stop the runner over the encrypted channel. Returns false when that is
    /// not possible (not paired, or the call failed), so the caller can fall
    /// back to ictrl://stop, which only asks for confirmation on the device.
    func stopRunner() async -> Bool {
        guard client.isPaired else { return false }
        do {
            _ = try await client.call("config", ["stop_server": true])
            ictrlLog("Runner admin: stopped the runner")
            return true
        } catch {
            handle(error)
            return false
        }
    }

    // MARK: - Logs

    func loadLogs() async {
        guard client.isPaired else { isPaired = false; return }
        do {
            let result = try await client.call("logs", ["max_elements": Self.logLineLimit])
            let lines = result["lines"] as? [String] ?? []
            if lines != logLines { logLines = lines }
            logsLoaded = true
            notice = nil
        } catch {
            handle(error)
        }
    }

    // MARK: - Helpers

    private func handle(_ error: Error) {
        switch error as? RunnerClient.Failure {
        case .notRunning:
            notice = L10n.t(.runnerNotRunningHint)
        case .notPaired:
            isPaired = false
        case .keyRejected:
            isPaired = false
            clients = []
            notice = L10n.t(.keyRejectedHint)
        case .pairDenied:
            notice = L10n.t(.pairDeniedHint)
        case .pairUnavailable(let seconds, _):
            notice = String(format: L10n.t(.retryInSeconds), seconds)
        case .server(let message):
            notice = message
        case nil:
            notice = error.localizedDescription
        }
        ictrlLog("Runner admin: \(error)")
    }

    private static let iso = ISO8601DateFormatter()

    /// The chosen setting. Nearby counts as chosen while it is switched on,
    /// advertised or not — otherwise "LAN" could not be picked to switch off
    /// a nearby discovery that is still waiting for Wi-Fi; `nearbyPending`
    /// tells the two apart for display.
    private static func parseVisibility(_ config: [String: Any]) -> Visibility? {
        guard let remote = config["allow_remote_access"] as? Bool else { return nil }
        guard remote else { return .local }
        let nearby = config["nearby"] as? [String: Any]
        return (nearby?["enabled"] as? Bool) == true ? .lanAndNearby : .lan
    }

    private static func parseClients(_ value: Any?) -> [Client] {
        let rows = value as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["session_id"] as? String else { return nil }
            return Client(id: id,
                          name: row["client_name"] as? String ?? id,
                          grantedAt: (row["granted_at"] as? String).flatMap(iso.date(from:)),
                          lastActiveAt: (row["last_active_at"] as? String).flatMap(iso.date(from:)),
                          lastAddress: row["last_address"] as? String,
                          lastVia: row["last_via"] as? String)
        }
        .sorted { ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast) }
    }
}
