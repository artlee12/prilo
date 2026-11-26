import Foundation
import Security

struct PCProfile: Codable {
    let id: UUID
    var name: String
    var host: String
    var wakeMAC: String?
    var wakeBroadcast: String?
    var wakeAutomatic: Bool?
    var receiverID: String?
}

struct PCSecrets: Codable, Equatable {
    let code: String
    let fingerprint: String
}

struct ControlSettings {
    static let defaultCursorSpeed: Double = 0.50
    static let defaultScrollSmoothness: Double = 1.50

    private let defaults = UserDefaults.standard

    var autoConnect: Bool {
        get { defaults.object(forKey: "autoConnect") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoConnect") }
    }
    var animate: Bool {
        get { defaults.object(forKey: "animateHandoff") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "animateHandoff") }
    }
    var commandIsControl: Bool {
        get { defaults.object(forKey: "commandIsControl") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "commandIsControl") }
    }
    var commandSpaceSwitchesLanguage: Bool {
        get { defaults.object(forKey: "commandSpaceSwitchesLanguage") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "commandSpaceSwitchesLanguage") }
    }
    var showLayoutIndicator: Bool {
        get { defaults.object(forKey: "showLayoutIndicator") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showLayoutIndicator") }
    }
    var clipboardSync: Bool {
        get { defaults.object(forKey: "clipboardSync") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "clipboardSync") }
    }
    var speed: Double {
        get { defaults.object(forKey: "cursorSpeed") as? Double ?? Self.defaultCursorSpeed }
        set { defaults.set(newValue, forKey: "cursorSpeed") }
    }
    var scrollSmoothness: Double {
        get { defaults.object(forKey: "scrollSmoothness") as? Double ?? Self.defaultScrollSmoothness }
        set { defaults.set(newValue, forKey: "scrollSmoothness") }
    }
    var commandLLocksWindows: Bool {
        get { defaults.object(forKey: "commandLLocksWindows") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "commandLLocksWindows") }
    }
    var keepWindowsAwake: Bool {
        get { defaults.object(forKey: "keepWindowsAwake") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keepWindowsAwake") }
    }
    var lockWindowsOnMacLock: Bool {
        get { defaults.object(forKey: "lockWindowsOnMacLock") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "lockWindowsOnMacLock") }
    }
    var threeFingerSwipeAction: ThreeFingerSwipeAction {
        get {
            (defaults.string(forKey: "threeFingerSwipeAction")).flatMap(ThreeFingerSwipeAction.init(rawValue:)) ?? .desktops
        }
        set { defaults.set(newValue.rawValue, forKey: "threeFingerSwipeAction") }
    }
    var threeFingerSwipeUp: Bool {
        get { defaults.object(forKey: "threeFingerSwipeUp") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "threeFingerSwipeUp") }
    }
    var threeFingerSwipeDown: Bool {
        get { defaults.object(forKey: "threeFingerSwipeDown") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "threeFingerSwipeDown") }
    }
    var pinchToZoom: Bool {
        get { defaults.object(forKey: "pinchToZoom") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pinchToZoom") }
    }
    var macShortcuts: Bool {
        get { defaults.object(forKey: "macShortcuts") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "macShortcuts") }
    }
    var fileTransferEnabled: Bool {
        get { defaults.object(forKey: "fileTransferEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "fileTransferEnabled") }
    }
    var clipboardFileSync: Bool {
        get { defaults.object(forKey: "clipboardFileSync") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "clipboardFileSync") }
    }
    var fileDestination: String {
        get { defaults.string(forKey: "fileDestination") ?? "downloads" }
        set { defaults.set(newValue, forKey: "fileDestination") }
    }
}

final class Profiles {
    private let defaults: UserDefaults
    private(set) var items: [PCProfile]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = defaults.data(forKey: "pcProfiles") ?? Data()
        items = (try? JSONDecoder().decode([PCProfile].self, from: data)) ?? []
    }

    var last: PCProfile? {
        let id = defaults.string(forKey: "lastPCProfile")
        return items.first { $0.id.uuidString == id }
    }

    func remember(name: String, host: String, id: UUID?, secrets: PCSecrets, wake: WakeTarget? = nil) throws -> PCProfile {
        let previous = items.first { $0.id == id }
        let automatic = previous?.wakeAutomatic ?? (previous?.wakeMAC == nil)
        let profile = PCProfile(id: previous?.id ?? UUID(), name: name.isEmpty ? host : name, host: host,
                                wakeMAC: (automatic ? wake?.mac : nil) ?? previous?.wakeMAC,
                                wakeBroadcast: (automatic ? wake?.broadcast : nil) ?? previous?.wakeBroadcast,
                                wakeAutomatic: automatic, receiverID: secrets.fingerprint)
        if try load(profile.id) != secrets {
            let data = try JSONEncoder().encode(secrets)
            let query = keychainQuery(profile.id)
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if update == errSecItemNotFound {
                var entry = query
                entry[kSecValueData as String] = data
                try check(SecItemAdd(entry as CFDictionary, nil))
            } else {
                try check(update)
            }
        }
        if let index = items.firstIndex(where: { $0.id == profile.id }) {
            items[index] = profile
        } else {
            items.append(profile)
        }
        defaults.set(try JSONEncoder().encode(items), forKey: "pcProfiles")
        defaults.set(profile.id.uuidString, forKey: "lastPCProfile")
        return profile
    }

    func rename(_ id: UUID, to name: String) throws -> PCProfile? {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !trimmed.isEmpty, let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        var updated = items
        updated[index].name = trimmed
        defaults.set(try JSONEncoder().encode(updated), forKey: "pcProfiles")
        items = updated
        return items[index]
    }

    func updateWake(_ id: UUID, mac: String, broadcast: String) throws -> PCProfile? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        var updated = items
        updated[index].wakeMAC = mac
        updated[index].wakeBroadcast = broadcast
        updated[index].wakeAutomatic = false
        defaults.set(try JSONEncoder().encode(updated), forKey: "pcProfiles")
        items = updated
        return items[index]
    }

    func load(_ id: UUID) throws -> PCSecrets? {
        var query = keychainQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { return nil }
        return try JSONDecoder().decode(PCSecrets.self, from: data)
    }

    func forget(_ id: UUID) throws {
        let status = SecItemDelete(keychainQuery(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
        items.removeAll { $0.id == id }
        defaults.set(try JSONEncoder().encode(items), forKey: "pcProfiles")
        if defaults.string(forKey: "lastPCProfile") == id.uuidString {
            defaults.removeObject(forKey: "lastPCProfile")
        }
    }

    private func keychainQuery(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.artlee12.prilo.pc",
         kSecAttrAccount as String: id.uuidString]
    }

    private func check(_ status: OSStatus) throws {
        if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
