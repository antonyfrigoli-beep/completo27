import Combine
import Foundation
import Security

@MainActor
final class LicenseManager: ObservableObject {

    @Published private(set) var expirationDate: Date?
    @Published private(set) var isActive = false
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var contactOwner: String?
    @Published var rememberKey = true

    private let service = "com.apple.mobile.MobileHouseArrest.activation"
    private let keyAccount = "license-key"
    private let validKeyAccount = "license-key-valid"
    private let expirationAccount = "license-key-expiration"
    private var lastAttemptAt: Date?

    init() {
        if let storedExpiration = string(for: expirationAccount) {
            expirationDate = Self.parseDate(storedExpiration)
        }
        isActive = hasRememberedValidKey && (expirationDate.map { $0 > Date() } ?? true)
        if !isActive { clearPatchSession() }
    }

    /// True only if a previously validated key is stored AND marked valid.
    var hasRememberedValidKey: Bool {
        string(for: validKeyAccount) == "true"
    }

    func beginLaunchSession() {
        // Re-validate on every launch; don't trust stale local state alone.
        isActive = false
        if hasRememberedValidKey, string(for: keyAccount) != nil {
            message = "Verificando licença…"
            // Background re-check so we catch revoked keys
            Task { await revalidateStoredKey() }
        } else {
            clearPatchSession()
            message = "Key required — enter your access key"
        }
    }

    /// Revalidates a remembered license after a temporary background transition
    /// without clearing the current UI session. Calling beginLaunchSession here
    /// would set isActive=false synchronously and present the login again.
    func refreshInForeground() {
        guard hasRememberedValidKey, string(for: keyAccount) != nil else { return }
        Task { await revalidateStoredKey() }
    }

    func activate(key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        if let lastAttemptAt, Date().timeIntervalSince(lastAttemptAt) < 1 {
            message = "Please wait a moment before trying again"
            return
        }
        lastAttemptAt = Date()
        isBusy = true
        message = "Checking access key…"

        Task {
            let result = await FilzaLicense.validate(key: trimmed)
            await MainActor.run {
                self.isBusy = false
                if result.valid {
                    self.isActive = true
                    self.message = "Activated successfully"
                    if self.rememberKey {
                        self.save(trimmed, for: self.keyAccount)
                        self.save("true", for: self.validKeyAccount)
                    }
                    if let exp = result.expiresAt ?? result.expiration,
                       let date = Self.parseDate(exp) {
                        guard date > Date() else {
                            self.isActive = false
                            self.clearStoredLicense()
                            self.clearPatchSession()
                            self.message = "A licença está expirada"
                            return
                        }
                        self.expirationDate = date
                        self.save(exp, for: self.expirationAccount)
                    } else {
                        self.expirationDate = nil
                        self.delete(self.expirationAccount)
                    }
                } else {
                    self.isActive = false
                    self.clearStoredLicense()
                    self.clearPatchSession()
                    let msg = result.detail ?? result.message ?? "Invalid access key"
                    self.message = msg
                }
            }
        }
    }

    /// Re-validate the stored key in the background.
    private func revalidateStoredKey() async {
        guard let stored = string(for: keyAccount) else { return }
        let result = await FilzaLicense.validate(key: stored)
        await MainActor.run {
            if !result.valid {
                self.isActive = false
                self.clearStoredLicense()
                self.clearPatchSession()
                self.message = "Key no longer valid — re-enter your key"
            } else if let exp = result.expiresAt ?? result.expiration,
                      let date = Self.parseDate(exp) {
                guard date > Date() else {
                    self.isActive = false
                    self.clearStoredLicense()
                    self.clearPatchSession()
                    self.message = "Key expired — re-enter your key"
                    return
                }
                self.expirationDate = date
                self.save(exp, for: self.expirationAccount)
                self.isActive = true
            } else {
                self.expirationDate = nil
                self.delete(self.expirationAccount)
                self.isActive = true
            }
        }
    }

    func rememberedKey() -> String? { string(for: keyAccount) }

    func refresh() {
        isActive = hasRememberedValidKey
        message = isActive ? "Ready to use" : "Key required — enter your access key"
    }

    func deactivate() {
        clearStoredLicense()
        clearPatchSession()
        isActive = false
        message = "Activation removed from this device"
    }

    private func clearStoredLicense() {
        delete(keyAccount)
        delete(validKeyAccount)
        delete(expirationAccount)
        expirationDate = nil
    }

    private func clearPatchSession() {
        PatchCatalogStore.shared.clearForInvalidLicense()
    }

    // MARK: - Keychain helpers

    private func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func save(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func parseDate(_ s: String) -> Date? {
        // Try ISO 8601 first, then a few common formats
        if let epoch = Double(s) {
            let seconds = epoch > 100_000_000_000 ? epoch / 1000.0 : epoch
            return Date(timeIntervalSince1970: seconds)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd"] {
            fmt.dateFormat = format
            if let d = fmt.date(from: s) { return d }
        }
        return nil
    }
}
