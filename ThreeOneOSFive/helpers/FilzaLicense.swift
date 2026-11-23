import Foundation
import CryptoKit

/// Result of a remote key validation.
struct FilzaValidationResult {
    let valid: Bool
    let message: String?
    let detail: String?
    let expiresAt: String?
    let expiration: String?
    let type: String?
    let lifetime: Bool?
}

/// Validates login keys through the publicCheckKey tRPC endpoint.
/// The other Filza backend routes (catalog, remote lock and announcements)
/// continue to use `baseURL`.
enum FilzaLicense {
    static let keyValidationEndpoint = URL(string: "https://proxysystem.org/api/trpc/proxyKeys.publicCheckKey")!
    static let baseURL   = "https://martins-license.duckdns.org/external"
    static let timeout: TimeInterval = 15

    private static let keychainService = "com.apple.mobile.MobileHouseArrest.activation"
    private static let keychainAccount = "license-key"

    private static func log(_ message: String) {
        #if DEBUG
        NSLog("[FilzaLicense] %@", message)
        #endif
    }

    private static func storedKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Device HWID (anti-crack binding)
    //
    // Derived from the device's anonymous identifier (ASIdentifierManager)
    // hashed with SHA-256. Not a fixed value – each device gets its own.
    // If the IDFA is unavailable (privacy), falls back to a stable UUID
    // stored in Keychain so the same device always presents the same HWID.

    static func deviceHWID() -> String {
        if let idfa = UIDevice.current.identifierForVendor?.uuidString {
            let data = Data(idfa.utf8)
            let hash = SHA256.hash(data: data)
            return hash.compactMap { String(format: "%02x", $0) }.joined()
        }
        // Fallback: persistent UUID in Keychain
        let service = "com.apple.mobile.MobileHouseArrest.hwid"
        let account = "device-id"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let d = result as? Data, let s = String(data: d, encoding: .utf8) {
            return s
        }
        let newID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var item = query
        item[kSecValueData as String] = Data(newID.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
        return newID
    }

    /// Returns true if the running binary's code signature is intact.
    /// A cracked/re-signed IPA will fail this check.
    static func verifyBinaryIntegrity() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        guard let exePath = Bundle.main.executablePath else { return false }

        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: exePath))
            defer { try? handle.close() }

            guard let header = try handle.read(upToCount: 4),
                  header.count == 4 else {
                return false
            }

            let magic = header.enumerated().reduce(UInt32(0)) { result, item in
                result | (UInt32(item.element) << UInt32(item.offset * 8))
            }

            return magic == 0xFEEDFACE ||
                   magic == 0xFEEDFACF ||
                   magic == 0xCEFAEDFE ||
                   magic == 0xCFFAEDFE
        } catch {
            return false
        }
        #endif
    }

    // MARK: - Public API

    /// Validate a key with the same tRPC GET contract used by the source app.
    /// `input` contains JSON shaped as {"json":{"key":"...","deviceId":"..."}}.
    /// The query-string form is required by this endpoint's publicCheckKey API.
    static func validate(key: String) async -> FilzaValidationResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return FilzaValidationResult(valid: false, message: nil, detail: nil,
                                          expiresAt: nil, expiration: nil, type: nil, lifetime: nil)
        }
        // Anti-crack: reject if binary integrity is broken
        guard verifyBinaryIntegrity() else {
            return FilzaValidationResult(valid: false, message: "Integrity check failed",
                                          detail: "App binary modified",
                                          expiresAt: nil, expiration: nil, type: nil, lifetime: nil)
        }
        let hwid = deviceHWID()

        do {
            let input: [String: Any] = ["json": ["key": trimmed, "deviceId": hwid]]
            let inputData = try JSONSerialization.data(withJSONObject: input)
            guard let inputJSON = String(data: inputData, encoding: .utf8) else {
                return FilzaValidationResult(valid: false, message: nil, detail: "Invalid validation request",
                                              expiresAt: nil, expiration: nil, type: nil, lifetime: nil)
            }
            var components = URLComponents(url: keyValidationEndpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "input", value: inputJSON)]
            guard let requestURL = components.url else {
                return FilzaValidationResult(valid: false, message: nil, detail: "Invalid validation URL",
                                              expiresAt: nil, expiration: nil, type: nil, lifetime: nil)
            }

            var req = URLRequest(url: requestURL)
            req.httpMethod = "GET"
            req.timeoutInterval = timeout
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: req)
            let http = (response as? HTTPURLResponse)?.statusCode ?? 0
            let parsed = parsePublicCheckKeyResponse(data)
            guard (200..<300).contains(http) else {
                return FilzaValidationResult(valid: false,
                                              message: parsed.message,
                                              detail: parsed.detail ?? "HTTP \(http)",
                                              expiresAt: parsed.expiresAt,
                                              expiration: parsed.expiration,
                                              type: parsed.type,
                                              lifetime: parsed.lifetime)
            }
            return parsed
        } catch {
            log("key validation request failed: \(error.localizedDescription)")
            return FilzaValidationResult(valid: false, message: nil,
                                          detail: "License validation service unavailable",
                                          expiresAt: nil, expiration: nil, type: nil, lifetime: nil)
        }
    }

    // MARK: - IPA Lock (remote kill switch)

    struct IpaLock {
        let active: Bool
        let message: String?
    }

    static func checkIpaLock() async -> IpaLock? {
        do {
            var req = URLRequest(url: URL(string: baseURL + "/v1/ipa_lock")!)
            req.timeoutInterval = timeout
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let active = (obj["active"] as? Bool) ?? false
            let msg = obj["message"] as? String
            return IpaLock(active: active, message: msg)
        } catch {
            return nil
        }
    }

    // MARK: - Global message

    struct GlobalMsg {
        let message: String?
        let msgId: Int
    }

    static func checkGlobalMessage() async -> GlobalMsg? {
        do {
            var req = URLRequest(url: URL(string: baseURL + "/v1/check_msg")!)
            req.timeoutInterval = timeout
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return GlobalMsg(message: obj["message"] as? String,
                             msgId: (obj["msg_id"] as? Int) ?? 0)
        } catch {
            return nil
        }
    }

    // MARK: - Catalog (online file updates)

    struct CatalogItem: Identifiable, Sendable {
        let id: String
        let name: String
        let img: String?
        let url: String
        let file: String
        let cat: String?
        let extra: Bool?
        let rank: Int?

        var remoteFilename: String {
            let name = file.isEmpty ? (URL(string: url)?.lastPathComponent ?? id) : file
            return URL(fileURLWithPath: name).lastPathComponent
        }

        // Stable opaque cache names prevent readable titles and server file
        // names from appearing in the local package directory.
        static func cacheFilename(catalogID: String, remoteFilename: String) -> String {
            let source = Data("patch-cache-v1|\(catalogID)|\(remoteFilename)".utf8)
            let digest = SHA256.hash(data: source)
            let opaque = digest.map { String(format: "%02x", $0) }.joined()
            return "\(opaque).r7v"
        }

        var localFilename: String {
            Self.cacheFilename(catalogID: id, remoteFilename: remoteFilename)
        }
    }

    struct Catalog: Sendable {
        let items: [CatalogItem]
    }

    static func fetchCatalog() async -> (catalog: Catalog?, failureMessage: String?) {
        guard let stored = storedKey() else {
            return (nil, "Nenhuma chave salva neste dispositivo.")
        }
        let key = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return (nil, "Nenhuma chave salva neste dispositivo.") }
        do {
            var req = URLRequest(url: URL(string: baseURL + "/v1/catalog")!)
            req.timeoutInterval = 30
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue(key, forHTTPHeaderField: "X-Filza-Key")
            req.setValue(deviceHWID(), forHTTPHeaderField: "X-Filza-Device")
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return (nil, "Resposta inválida do servidor do catálogo.")
            }
            guard (200..<300).contains(http.statusCode) else {
                let message: String
                switch http.statusCode {
                case 401, 403:
                    message = "O catálogo Filza recusou esta chave (HTTP \(http.statusCode)). Peça ao revendedor para confirmar se ela está ativa no servidor do catálogo."
                case 429:
                    message = "O catálogo Filza está temporariamente ocupado. Tente novamente em instantes."
                default:
                    message = "O servidor do catálogo respondeu HTTP \(http.statusCode). Tente novamente mais tarde."
                }
                log("catalog request rejected with HTTP \(http.statusCode)")
                return (nil, message)
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["items"] as? [[String: Any]] else {
                return (nil, "O servidor enviou uma lista de opções inválida.")
            }
            let items = arr.compactMap { o -> CatalogItem? in
                guard let id = o["id"] as? String,
                      let url = o["url"] as? String else { return nil }
                return CatalogItem(
                    id: id,
                    name: o["name"] as? String ?? id,
                    img: o["img"] as? String,
                    url: url,
                    file: o["file"] as? String ?? "",
                    cat: o["cat"] as? String,
                    extra: o["extra"] as? Bool,
                    rank: o["rank"] as? Int
                )
            }
            return (Catalog(items: items), nil)
        } catch {
            log("catalog request failed: \(error.localizedDescription)")
            return (nil, "Não foi possível conectar ao servidor do catálogo. Verifique sua internet.")
        }
    }

    private static func openTransport(_ data: Data, key: String, itemID: String, filename: String) throws -> Data {
        let magic = Data("FPT1".utf8)
        guard data.starts(with: magic) else { return data } // compatibility with old servers during rollout
        guard data.count > magic.count + 12 else { throw PatchPackageError.remoteImportFailed }
        let transportKey = Data(SHA256.hash(data: Data("filza-transport-v1:\(key):\(itemID)".utf8)))
        let nonce = data.subdata(in: magic.count..<(magic.count + 12))
        let ciphertext = data.subdata(in: (magic.count + 12)..<data.count)
        let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonce), ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
        return try AES.GCM.open(box, using: SymmetricKey(data: transportKey), authenticating: Data("\(itemID):\(filename)".utf8))
    }

    /// Download a single catalog item into the authenticated online patch library.
    @discardableResult
    static func downloadItem(_ item: CatalogItem) async -> URL? {
        guard let url = URL(string: item.url), let stored = storedKey() else { return nil }
        let key = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        guard let destDir = try? PatchProjectLibrary.packageRootURL() else { return nil }
        let requestedName = item.file.isEmpty ? url.lastPathComponent : item.file
        let normalizedName = URL(fileURLWithPath: requestedName).lastPathComponent
        let filename = item.localFilename
        let dest = destDir.appendingPathComponent(filename)
        var stage = "download request"
        do {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 120
            config.timeoutIntervalForResource = 600
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: url)
            request.setValue(key, forHTTPHeaderField: "X-Filza-Key")
            request.setValue(deviceHWID(), forHTTPHeaderField: "X-Filza-Device")
            request.setValue("1", forHTTPHeaderField: "X-Filza-Transport")
            let (tmp, response) = try await session.download(for: request)
            stage = "HTTP response validation"
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            stage = "transport authentication"
            let raw = try Data(contentsOf: tmp, options: .mappedIfSafe)
            let data: Data
            do {
                // The server authenticates the exact filename stored in its
                // catalog. Try that unchanged value first; use the basename
                // only for older catalogs that included a path prefix.
                data = try openTransport(raw, key: key, itemID: item.id, filename: requestedName)
            } catch {
                guard normalizedName != requestedName else { throw error }
                data = try openTransport(raw, key: key, itemID: item.id, filename: normalizedName)
            }
            stage = "package validation"
            _ = try PatchPackageCodec.inspect(data)
            stage = "protected cache write"
            // `tmp` still contains the FPT1 transport envelope. Publish the
            // already-decrypted package data through the at-rest cache writer;
            // moving `tmp` here would make every package fail its final check.
            _ = try PatchProjectLibrary.save(
                data: data,
                projectName: filename,
                // Always use the catalog filename. Passing nil here makes the
                // generic importer append `.OGIOS`, so the catalog lookup can
                // never find the downloaded package on its first download.
                existingURL: dest
            )
            // Final read/inspect gate: never report success for a corrupt or empty package.
            stage = "cache verification"
            let published = try PatchProjectLibrary.readPackage(at: dest)
            _ = try PatchPackageCodec.inspect(published)
            return dest
        } catch {
            let nsError = error as NSError
            log("catalog download failed for item \(item.id) at \(stage) (domain=\(nsError.domain), code=\(nsError.code))")
            return nil
        }
    }

    // MARK: - Active Keys Counter

    /// Fetches the total number of currently active keys from the backend.
    /// Returns nil if the endpoint is unavailable or returns an error.
    static func fetchActiveKeysCount() async -> Int? {
        do {
            var req = URLRequest(url: URL(string: baseURL + "/v2/filza/keys/active-count")!)
            req.httpMethod = "GET"
            req.timeoutInterval = 8
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("FilzaBypass/1.1", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: req)
            let http = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard http == 200 else { return nil }

            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let count = obj["used_keys"] as? Int { return count }
            if let count = obj["bound_keys"] as? Int { return count }
            if let count = obj["count"] as? Int { return count }
            if let count = obj["active_keys"] as? Int { return count }
            if let count = obj["total"] as? Int { return count }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - Parsing (tolerant – fields are optional)
    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func parsePublicCheckKeyResponse(_ data: Data) -> FilzaValidationResult {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return FilzaValidationResult(valid: false, message: nil, detail: "Bad JSON",
                                         expiresAt: nil, expiration: nil, type: nil, lifetime: nil)
        }
        let result = obj["result"] as? [String: Any] ?? [:]
        let dataWrapper = result["data"] as? [String: Any] ?? [:]
        let payload = dataWrapper["json"] as? [String: Any] ?? obj
        let error = obj["error"] as? [String: Any] ?? [:]
        let errorJSON = error["json"] as? [String: Any] ?? [:]

        let status = stringValue(payload["status"])?.lowercased()
        let valid = (payload["success"] as? Bool) == true
            && (payload["active"] as? Bool) == true
            && status == "active"
        let serverMessage = stringValue(payload["message"])
            ?? stringValue(payload["reason"])
            ?? stringValue(errorJSON["message"])
        let message = valid ? serverMessage : (serverMessage ?? (status == "device_mismatch"
            ? "Esta chave já está vinculada a outro aparelho."
            : "Chave inválida ou expirada."))
        let expiresAt = stringValue(payload["expiresAt"] ?? payload["expires_at"])

        return FilzaValidationResult(valid: valid,
                                     message: message,
                                     detail: nil,
                                     expiresAt: expiresAt,
                                     expiration: nil,
                                     type: nil,
                                     lifetime: nil)
    }
}
