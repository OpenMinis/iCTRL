import Foundation
import IDevice
import UniformTypeIdentifiers

/// Where the device pairing record lives.
///
/// The mount opens a RemotePairing tunnel to this device, so the file has to be
/// a RemotePairing (RP) record: a plist with an Ed25519 `public_key` /
/// `private_key` pair and a host `identifier` (plus an optional `alt_irk`).
/// That is what StikDebug stores (`pairingFile.plist`, formerly
/// `rp_pairing_file.plist`) and what idevice_pair writes for "Remote pairing".
/// An older lockdown record (`HostID`, `HostCertificate`, … as written by
/// `idevicepair pair` or kept by SideStore) cannot open that tunnel.
enum PairingFileStore {

    /// Types the import picker accepts.
    ///
    /// `.fileImporter` matches a picked file's type against this list, and the
    /// match has to hold for the file's *actual* UTI. A pairing record is an
    /// XML property list, which iOS types as `public.xml` — a sibling of
    /// `public.data`, not a subtype, so `.data` alone does not let it through.
    ///
    /// Two traps made the old list miss real files:
    ///  * `UTType(filenameExtension:)` returns nil for `plist` /
    ///    `mobiledevicepairing` on iOS — no such UTI is registered — so those
    ///    entries silently vanished and the list collapsed to `.data`.
    ///  * A picker only enables what the list *contains*; `.xml` has to be
    ///    listed on its own because it is not covered by `.data`.
    ///
    /// So declare every type explicitly with `UTType(tag:tagClass:conformingTo:)`
    /// (which does not depend on a system-registered UTI) and keep `.data` last
    /// as the permissive catch-all. The file is validated after the pick anyway,
    /// so a wider list costs nothing but a clearer failure.
    static let supportedContentTypes: [UTType] = {
        var types: [UTType] = []

        // The standard property-list type (both XML and binary forms).
        types.append(.propertyList)
        // A pairing record is usually XML: iOS reports `public.xml`, and the
        // picker must be told about it explicitly.
        types.append(.xml)

        // Apple's tooling and the community write these extensions. Build the
        // types from their tags rather than by filename lookup, so they exist
        // even where the system has no UTI registered for the extension.
        for ext in ["mobiledevicepairing", "mobiledevicepair"] {
            if let t = UTType(tag: ext, tagClass: .filenameExtension,
                              conformingTo: .propertyList) {
                types.append(t)
            }
        }
        // A plain `.plist` extension, in case the file keeps it.
        if let t = UTType(tag: "plist", tagClass: .filenameExtension,
                          conformingTo: .propertyList) {
            types.append(t)
        }

        // Permissive catch-all: every file conforms to `.data`, so this keeps
        // the picker from greying out a record saved under an unexpected
        // extension. Content is validated by `validate(_:)` after import.
        types.append(.data)

        return types
    }()

    /// Application Support/Pairing/pairingFile.plist — outside Documents so it
    /// isn't casually deleted from the Files app, since losing it means
    /// re-pairing from a Mac.
    static var storedURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Pairing/pairingFile.plist")
    }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: storedURL.path)
    }

    /// When the current file was imported — shown in the UI so a stale pairing
    /// file (a common cause of confusing mount failures) is at least visible.
    static var importedAt: Date? {
        try? FileManager.default.attributesOfItem(atPath: storedURL.path)[.modificationDate] as? Date
    }

    /// Copy a user-picked file into place.
    ///
    /// The picker hands back a security-scoped URL that is only readable inside
    /// a start/stop pair, so the bytes are copied out immediately rather than
    /// holding the URL.
    static func importFile(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        try validate(data)

        let dest = storedURL
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // 0600 from the start: this file authenticates as a trusted host to the
        // device, so it deserves the same care as a private key.
        try data.write(to: dest, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: dest.path)
        ictrlLog("Pairing file imported (\(data.count)B)")
    }

    /// Posted after a pairing file is stored, so a screen showing the old
    /// state can refresh.
    static let didImport = Notification.Name("PairingFileStore.didImport")

    /// Store a file shared to the app ("Open in iCTRL"). iOS hands over a copy
    /// in an inbox folder of ours (Documents/Inbox, or tmp/<bundle id>-Inbox
    /// on newer systems), which is removed afterwards whatever the outcome.
    static func importShared(from url: URL) throws {
        defer {
            if url.deletingLastPathComponent().lastPathComponent.hasSuffix("Inbox") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try importFile(from: url)
        NotificationCenter.default.post(name: didImport, object: nil)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: storedURL)
    }

    /// Reject anything the mount could not use, so the failure lands at import
    /// time with a clear message instead of surfacing later as an opaque error
    /// from deep inside the mount.
    ///
    /// The check is the parser the mount itself uses, so a file that passes
    /// here is one the mount can read. The plist is only inspected to explain
    /// a rejection.
    static func validate(_ data: Data) throws {
        if parsesAsRemotePairing(data) { return }

        let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = plist as? [String: Any] else {
            throw DDIError.invalidPairingFile("Not a property list. Expected a RemotePairing file, "
                + "such as StikDebug's pairingFile.plist.")
        }
        if dict["HostID"] != nil || dict["HostCertificate"] != nil {
            throw DDIError.invalidPairingFile("This is a lockdown pairing file (as written by "
                + "`idevicepair pair` or kept by SideStore). Mounting needs a RemotePairing file: "
                + "use StikDebug's pairingFile.plist, or create one with idevice_pair "
                + "(choose Remote pairing) or iLoader.")
        }
        throw DDIError.invalidPairingFile("A property list, but not a RemotePairing file: it needs "
            + "public_key, private_key and identifier.")
    }

    private static func parsesAsRemotePairing(_ data: Data) -> Bool {
        var handle: OpaquePointer?
        let err = data.withUnsafeBytes { raw -> UnsafeMutablePointer<IdeviceFfiError>? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return rp_pairing_file_from_bytes(base, UInt(raw.count), &handle)
        }
        if let err { idevice_error_free(err) }
        if let handle { rp_pairing_file_free(handle) }
        return err == nil && handle != nil
    }
}
