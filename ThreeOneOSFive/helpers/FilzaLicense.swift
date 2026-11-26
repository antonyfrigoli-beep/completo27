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

enum PatchHubDownloadOutcome: Sendable {
    case success(URL)
    case failure(String)
}

/// Validates GH777 license keys through the Cloudflare Worker and consumes
/// the authenticated PatchHub feed.
enum FilzaLicense {
    static let keyValidationEndpoint = URL(string: "https://gh777-license-api.marcelamartinszx12.workers.dev/api/keys/validate")!
    static let patchHubBaseURL = URL(string: "https://gh777-patch-feed.marcelamartinszx12.workers.dev")!
    static let timeout: TimeInterval = 15

    private static func log(_ message: String) {
        #if DEBUG
        NSLog("[FilzaLicense] %@", message)
        #endif
    }

    private static func downloadFailureMessage(_ error: Error, stage: String) -> String {
        if stage == "package validation", let packageError = error as? PatchPackageError {
            switch packageError {
            case .unsupportedFormat:
                return "O servidor não enviou um pacote .3105 compatível com o app (pode ter retornado uma página HTML ou outro arquivo)."
            case .unsupportedVersion:
                return "O pacote .3105 usa uma versão que esta versão do app não reconhece."
            case .invalidPasswordOrCorruptedPackage:
                return "O pacote .3105 está incompleto ou corrompido."
            default:
                return "O conteúdo recebido não passou pela validação do pacote .3105."
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "Sem conexão com a internet para baixar o pacote."
            case .timedOut:
                return "O servidor demorou para responder; tente baixar novamente."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost:
                return "Não foi possível conectar ao servidor do PatchHub."
            default:
                return "Falha de rede ao baixar o pacote .3105."
            }
        }
        switch stage {
        case "protected cache write":
            return "O pacote foi recebido, mas não pôde ser salvo no cache protegido do app."
        case "cache verification":
            return "O pacote foi salvo, mas a verificação do cache protegido falhou."
        default:
            return "Não foi possível validar ou salvar o pacote .3105."
        }
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

    /// Validate a GH777 key. The Worker accepts a JSON POST body containing
    /// the key and this installation's stable device identifier.
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
            let input: [String: Any] = ["key": trimmed, "deviceId": hwid]
            let inputData = try JSONSerialization.data(withJSONObject: input)
            var req = URLRequest(url: keyValidationEndpoint)
            req.httpMethod = "POST"
            req.timeoutInterval = timeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.httpBody = inputData

            let (data, response) = try await URLSession.shared.data(for: req)
            let http = (response as? HTTPURLResponse)?.statusCode ?? 0
            let parsed = parseGH777ValidationResponse(data)
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

    // MARK: - Catalog (online file updates)

    struct CatalogItem: Identifiable, Sendable, Codable {
        let id: String
        let name: String
        let img: String?
        let url: String
        let file: String
        let cat: String?
        let password: String?
        let extra: Bool?
        let rank: Int?
        let packageSize: Int?
        let packageSha256: String?
        let isPasswordProtected: Bool?

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

    struct Catalog: Sendable, Codable {
        let items: [CatalogItem]
    }

    private static func patchHubResolvedURL(_ rawURL: String?, baseURL: URL) -> String? {
        guard let rawURL = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty,
              let resolved = URL(string: rawURL, relativeTo: baseURL)?.absoluteURL,
              resolved.scheme?.lowercased() == "https",
              resolved.host?.lowercased() == baseURL.host?.lowercased() else {
            return nil
        }
        return resolved.absoluteString
    }

    static func fetchCatalog() async -> (catalog: Catalog?, failureMessage: String?) {
        do {
            let catalogURL = patchHubBaseURL
                .appendingPathComponent("api")
                .appendingPathComponent("mobile")
                .appendingPathComponent("catalog")
            var req = URLRequest(url: catalogURL)
            req.timeoutInterval = 30
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return (nil, "Resposta inválida do servidor PatchHub.")
            }
            guard http.url?.scheme?.lowercased() == "https",
                  http.url?.host?.lowercased() == patchHubBaseURL.host?.lowercased() else {
                return (nil, "O feed PatchHub respondeu por um endereço HTTPS inesperado.")
            }
            guard (200..<300).contains(http.statusCode) else {
                let message: String
                switch http.statusCode {
                case 401, 403:
                    message = "O PatchHub recusou a solicitação (HTTP \(http.statusCode))."
                case 429:
                    message = "O PatchHub está temporariamente ocupado. Tente novamente em instantes."
                default:
                    message = "O PatchHub respondeu HTTP \(http.statusCode). Tente novamente mais tarde."
                }
                log("catalog request rejected with HTTP \(http.statusCode)")
                return (nil, message)
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["patches"] as? [[String: Any]] else {
                return (nil, "O PatchHub enviou uma lista de patches inválida.")
            }
            let items = arr.compactMap { o -> CatalogItem? in
                guard (o["maintenance"] as? Bool) != true,
                      let id = o["id"] as? String,
                      let feature = o["feature"] as? String,
                      let category = PatchCatalog.Category(remoteFeature: feature),
                      let packageURL = patchHubResolvedURL(o["packageURL"] as? String, baseURL: patchHubBaseURL),
                      let file = o["packageFilename"] as? String,
                      !file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                let iconURL = patchHubResolvedURL(o["iconURL"] as? String, baseURL: patchHubBaseURL)
                return CatalogItem(
                    id: id,
                    name: o["name"] as? String ?? id,
                    img: iconURL,
                    url: packageURL,
                    file: file,
                    cat: category.rawValue,
                    // PatchHub publishes `password`; accept its storage name as
                    // a compatibility fallback so a VPS with the newer API
                    // cannot silently drop the automatic unlock credential.
                    password: (o["password"] as? String) ?? (o["packagePassword"] as? String),
                    extra: o["extra"] as? Bool,
                    rank: o["rank"] as? Int,
                    packageSize: o["packageSize"] as? Int,
                    packageSha256: o["packageSha256"] as? String,
                    isPasswordProtected: o["isPasswordProtected"] as? Bool
                )
            }
            guard arr.isEmpty || !items.isEmpty else {
                return (nil, "O site listou patches, mas nenhum tem categoria, URL HTTPS e nome de arquivo compatíveis com o app.")
            }
            return (Catalog(items: items), nil)
        } catch {
            log("catalog request failed: \(error.localizedDescription)")
            return (nil, "Não foi possível conectar ao PatchHub. Verifique a conexão e tente novamente.")
        }
    }

    /// Download and validate one package from the public PatchHub feed.
    @discardableResult
    static func downloadItem(_ item: CatalogItem) async -> PatchHubDownloadOutcome {
        guard let url = URL(string: item.url),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == patchHubBaseURL.host?.lowercased() else {
            return .failure("O link do pacote não usa HTTPS no domínio autorizado do PatchHub.")
        }
        guard let destDir = try? PatchProjectLibrary.packageRootURL() else {
            return .failure("Não foi possível abrir o cache protegido do app.")
        }
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
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            let (tmp, response) = try await session.download(for: request)
            stage = "HTTP response validation"
            guard let http = response as? HTTPURLResponse else {
                return .failure("O PatchHub devolveu uma resposta HTTP inválida.")
            }
            guard http.url?.scheme?.lowercased() == "https",
                  http.url?.host?.lowercased() == patchHubBaseURL.host?.lowercased() else {
                return .failure("O download foi redirecionado para um domínio HTTPS não autorizado.")
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure("O servidor PatchHub respondeu HTTP \(http.statusCode).")
            }
            let data = try Data(contentsOf: tmp, options: .mappedIfSafe)
            stage = "package validation"
            if let expectedSize = item.packageSize, data.count != expectedSize {
                return .failure("O tamanho do pacote recebido não corresponde ao catálogo.")
            }
            if let expectedHash = item.packageSha256?.lowercased(), expectedHash.count == 64 {
                let actualHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard actualHash == expectedHash else {
                    return .failure("A assinatura SHA-256 do pacote não corresponde ao catálogo.")
                }
            }
            let summary = try PatchPackageCodec.inspect(data)
            if let publishedProtection = item.isPasswordProtected,
               publishedProtection != summary.isPasswordProtected {
                return .failure("O estado de proteção do pacote não corresponde ao catálogo.")
            }
            if summary.isPasswordProtected {
                guard let password = item.password?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !password.isEmpty else {
                    return .failure("O PatchHub marcou este patch como protegido, mas não enviou uma senha válida.")
                }
                do {
                    let decoded = try PatchPackageCodec.decode(data, password: password)
                    try PatchKeyStore.store(decoded.contentKey, for: summary)
                } catch {
                    try? FileManager.default.removeItem(at: dest)
                    return .failure("A senha enviada pelo PatchHub não desbloqueou este patch. Verifique a senha publicada no site.")
                }
            }
            stage = "protected cache write"
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
            return .success(dest)
        } catch {
            let nsError = error as NSError
            log("catalog download failed for item \(item.id) at \(stage) (domain=\(nsError.domain), code=\(nsError.code))")
            return .failure(downloadFailureMessage(error, stage: stage))
        }
    }

    // MARK: - Parsing (tolerant – fields are optional)
    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func parseGH777ValidationResponse(_ data: Data) -> FilzaValidationResult {
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
