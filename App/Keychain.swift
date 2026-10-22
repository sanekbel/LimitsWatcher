import Foundation
import Security

/// Secrets typed into the settings window (Admin key, Cursor cookie, Copilot token) live in the Keychain.
enum Keychain {
    private static let service = "limitswatcher.secrets"

    private static func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func get(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String?) {
        let query = base(account)
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    /// UserDefaults flag: the user picked "Always Allow" in the macOS prompt for another app's item.
    static let foreignAlwaysAllowedKey = "keychainAlwaysAllowed"

    /// Reads another app's generic-password item by service name (e.g. "Claude Code-credentials").
    ///
    /// Until the user has picked "Always Allow", every read goes through the standard macOS prompt.
    /// macOS forgets that choice whenever Claude Code rewrites its item (on login and on every token refresh),
    /// so once it is given, it is remembered here and later reads go through /usr/bin/security: Claude Code
    /// writes the item with that tool, so it stays on the item's access list and the read needs no prompt.
    /// Turning the setting off brings the prompt back.
    static func readForeign(service: String) -> Data? {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: foreignAlwaysAllowedKey), let data = readWithSecurityTool(service: service) {
            return data
        }
        guard let data = copyForeign(service: service, interactive: true) else { return nil }
        // Right after the prompt the item is readable without one only if "Always Allow" was picked;
        // a plain "Allow" is good for that single read.
        if copyForeign(service: service, interactive: false) != nil {
            defaults.set(true, forKey: foreignAlwaysAllowedKey)
        }
        return data
    }

    private static func copyForeign(service: String, interactive: Bool) -> Data? {
        // The login keychain is a file-based one: its access prompts can only be switched off process-wide.
        if !interactive { SecKeychainSetUserInteractionAllowed(false) }
        defer { if !interactive { SecKeychainSetUserInteractionAllowed(true) } }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func readWithSecurityTool(service: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        // `-w` prints the secret followed by a newline.
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Data(trimmed.utf8)
    }
}
