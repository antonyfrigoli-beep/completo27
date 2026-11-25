#!/usr/bin/env python3
"""Static security contract checks for the Filza V5 patch cache and UI."""
from __future__ import annotations

from pathlib import Path
import plistlib
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "ThreeOneOSFive"


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8", errors="replace")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)
    print("PASS:", message)


def between(source: str, start: str, end: str) -> str:
    i = source.find(start)
    if i < 0:
        raise ValueError("missing source marker: " + start)
    j = source.find(end, i + len(start))
    if j < 0:
        raise ValueError("missing source marker: " + end)
    return source[i:j]


def main() -> int:
    project = read("ThreeOneOSFive/helpers/PatchProjectLibrary.swift")
    crypto = between(project, "enum PatchAtRestCrypto", "struct PatchLibraryItem")
    save = between(project, "    static func save(", "    static func installImportedPackage(")
    ensure = between(project, "    static func ensureProtectedAtRest(", "    static func save(")
    load = between(project, "    static func load(", "    private static func migrateOpaqueCatalogURLIfNeeded(")

    require('AES.GCM.seal(data, using: try key(), authenticating: Data(filename.utf8))' in crypto,
            "cache payloads use authenticated AES-GCM with filename-bound AAD")
    require('AES.GCM.open(box, using: try key(), authenticating: Data(filename.utf8))' in crypto,
            "cache reads authenticate ciphertext and reject tampering or renamed files")
    require('result.append(combined)' in crypto and 'private static let magic = Data("FPENC1\\0".utf8)' in crypto,
            "encrypted files use the explicit FPENC1 AES-GCM envelope")
    require('PatchAtRestCrypto.seal(data, filename: destination.lastPathComponent)' in save
            and '.completeFileProtection' in save,
            "every saved local package is encrypted before atomic, file-protected write")
    require('try ensureProtectedAtRest(at: url, fileManager: fileManager)' in load
            and 'if !isProtectedAtRest(at: url)' in load
            and 'try? fileManager.removeItem(at: url)' in load,
            "legacy plaintext is encrypted before use or deleted on migration failure")
    imported = between(project, "    static func installImportedPackage(", "    static func delete(")
    require('previousData.write' not in imported and '_ = try? save(' in imported,
            "failed package replacement restores the previous item only through encrypted save")
    require('for: .applicationSupportDirectory' in project
            and 'appendingPathComponent(".fp-session"' in project
            and 'appendingPathComponent(".packages"' in project
            and 'values.isHidden = true' in project,
            "package cache is persistent in hidden Application Support, not tmp/Documents")

    catalog = read("ThreeOneOSFive/helpers/PatchCatalogStore.swift")
    catalog_exists = between(catalog, "    private nonisolated static func isValidCachedPackage(", "    private static func normalizedCategory(")
    require('ensureProtectedAtRest(at: url)' in catalog_exists
            and 'readPackage(at: url)' in catalog_exists,
            "remote catalog only reports a cache ready after protected read succeeds")
    refresh = between(catalog, "    func refresh() async {", "    private func publishCatalogIfChanged(")
    require("publishCatalogIfChanged(incoming)" in refresh
            and refresh.index("publishCatalogIfChanged(incoming)") < refresh.index("let batchSize = 2")
            and "let batchSize = 2" in refresh,
            "catalog options appear before automatic two-at-a-time prefetch")
    require("inFlightDownloads" in catalog and "Task.detached(priority: .utility)" in catalog,
            "prefetch reuses in-flight downloads and validates encrypted cache off the UI thread")

    license = read("ThreeOneOSFive/helpers/FilzaLicense.swift")
    cache_name = between(license, "        static func cacheFilename(", "        var localFilename")
    require('SHA256.hash(data: source)' in cache_name and '.r7v' in cache_name
            and 'catalogID' in cache_name and 'remoteFilename' in cache_name,
            "local .r7v filenames are stable opaque SHA-256 names, not server titles")

    server = read("server/filza_control.py")
    legacy_auth = between(server, "def legacy_license_key(", "def get_control(")
    catalog_auth = between(server, "def authorized_request(", "def catalog(")
    require("if not activate and row['status'] != 'used':" in legacy_auth
            and "legacy_license_key(key, device_id, activate=False)" in catalog_auth
            and "allow_legacy=True" in server,
            "catalog accepts only already-activated legacy reseller keys and does not consume unused keys")
    license_catalog = between(license, "    static func fetchCatalog()", "    /// Download and validate one package from the public PatchHub feed.")
    license_download = between(license, "    static func downloadItem(", "    // MARK: - Parsing")
    require('appendingPathComponent("mobile")' in license_catalog
            and 'appendingPathComponent("catalog")' in license_catalog
            and 'obj["patches"]' in license_catalog
            and '"feature"' in license_catalog and '"packageURL"' in license_catalog,
            "client consumes PatchHub /api/mobile/catalog and maps feature/package fields")
    require('patchHubResolvedURL' in license
            and 'resolved.scheme?.lowercased() == "https"' in license
            and 'resolved.host?.lowercased() == baseURL.host?.lowercased()' in license
            and 'http.url?.host?.lowercased() == patchHubBaseURL.host?.lowercased()' in license_download
            and not any(header in license for header in ('X-Filza-Key', 'X-Filza-Device', 'X-Filza-Transport')),
            "PatchHub package and icon URLs are HTTPS/same-host and receive no license headers")
    require('enum PatchHubDownloadOutcome' in license
            and 'case .unsupportedFormat:' in license
            and 'respondeu HTTP' in license_download
            and 'cache protegido do app' in license,
            "PatchHub download reports format, HTTP, and protected-cache failures without weakening package validation")
    require('let password = item.password?' in license_download
            and 'PatchKeyStore.store(decoded.contentKey, for: summary)' in license_download
            and 'senha enviada pelo PatchHub não desbloqueou' in license_download,
            "PatchHub package passwords unlock content keys and fail closed when invalid")
    codec = read("ThreeOneOSFive/helpers/PatchPackageCodec.swift")
    require('latestReadableSchemaVersion = 3' in codec
            and 'latestWritableSchemaVersion = 2' in codec
            and 'schemaVersion: latestWritableSchemaVersion' in codec
            and 'payloadAAD(for: envelope.packageID, version: envelope.schemaVersion)' in codec
            and '(minimumSchemaVersion...latestWritableSchemaVersion)' in codec
            and '(minimumSchemaVersion...latestReadableSchemaVersion).contains(schemaVersion)' in codec,
            "schema 3 packages are read with authenticated payloads, preserved on edit, and fresh packages/password AAD stay conservative")
    require('Nenhum patch .3105 está publicado no PatchHub' in catalog
            and 'ERRO NO DOWNLOAD — \\(reason)' in catalog
            and 'Task<PatchHubDownloadOutcome, Never>' in catalog,
            "empty PatchHub feeds and per-item failures have an explicit user-facing diagnosis")

    workspace = read("ThreeOneOSFive/helpers/PatchWorkspaceService.swift")
    require('removeItem(at: url)' in workspace
            and not re.search(r'createDirectory|write\s*\(|synchronizeWorkspace|snapshotWorkspace|documentsRootURL', workspace),
            "workspace compatibility service only removes legacy data; it cannot create plaintext workspaces")
    store = read("ThreeOneOSFive/helpers/PatchProjectStore.swift")
    require('PatchProjectLibrary.purgeLegacyBundledArtifacts()' in store
            and 'PatchWorkspaceService.clearWorkspaceArtifacts' in project,
            "legacy plaintext workspace folders are removed during app startup")
    project_views = read("ThreeOneOSFive/views/PatchProjectsView.swift")
    require('workspaceURL' not in project_views and 'synchronizeWorkspace' not in project_views,
            "patch UI has no workspace path/link and applies from the in-memory model")
    app_browser = read("ThreeOneOSFive/views/AppDataBrowserView.swift")
    require('workspaceURL' not in app_browser and 'documentsRootURL' not in app_browser,
            "app-data browser does not expose a plaintext workspace route")
    file_browser = read("ThreeOneOSFive/views/FileBrowserView.swift")
    require('.workspaces' in file_browser and '.fp-session' in file_browser and 'pathComponents.contains' in file_browser,
            "file browser hides internal cache paths and blocks legacy workspace deep links")

    view = read("ThreeOneOSFive/ContentView.swift")
    required_categories = [
        'case cache = "CACHE"', 'case avatar = "AVATAR"', 'case skin = "SKIN"',
        'case external = "EXTERNAL"', 'case hologram = "HOLOGRAM"',
        'return "Cachê"', 'return "Avatar"', 'return "Skin"',
        'return "External"', 'return "Holograma"',
    ]
    require(all(category in view for category in required_categories)
            and 'ForEach(GameTab.allCases' in view
            and not any(old in view for old in ('case ffNormal =', 'case ffMax =', 'case ap =', 'case textures =', 'case others =')),
            "dashboard renders only the five requested PatchHub categories")
    require('isMenuExpanded.toggle()' in view
            and 'line.3.horizontal' in view
            and 'Text("CATEGORIAS")' in view
            and 'selectedGameTab = tab' in view
            and 'selectedMainPage = 1' in view
            and 'TutorialsView()' in view
            and 'showSettings = true' in view,
            "expanding menu contains five categories, Tutorials and Settings")
    require('Text("FILZA EXTERNAL BYPASS")' not in view
            and 'TOMMY' not in view
            and 'Patchs' in view,
            "minimal patch dashboard has no brand header and retains the Patchs title")
    require('isBusy: onlineCatalog.isRefreshing' not in view and 'LazyVStack(spacing: 10)' in view,
            "background catalog refresh does not dim the whole options list; rows are lazy-rendered")
    require('modeSelectionButton' not in view
            and '@AppStorage("filzaBypass.automaticPatchMode")' not in view
            and 'Automático' not in view
            and 'downloadOnly(remote)' not in view
            and 'onlineCatalog.toggle(remote)' in view
            and 'UserDefaults.standard.set(false, forKey: "filzaBypass.automaticPatchMode")' in view
            and 'Ativação manual: toque em um patch para ativar ou desativar.' in view
            and 'startGameLaunchTimer' not in view
            and 'recoverExpiredTemporaryPatchIfNeeded' not in view,
            "all patch activation and restoration is manual; old automatic mode/timers are disabled")
    tutorials = read("ThreeOneOSFive/TutorialsView.swift")
    require('return remoteItems' in tutorials
            and 'Nenhum tutorial publicado no momento.' in tutorials
            and 'VideoPlayer(player: player)' in tutorials
            and 'tutorial_error_others' not in tutorials,
            "tutorial page is empty until new remote videos are published")
    settings = read("ThreeOneOSFive/views/SettingsView.swift")
    require('AppLogo' not in settings
            and 'FILZA EXTERNAL BYPASS' not in settings
            and 'CENTRAL DE CONFIGURAÇÕES' not in settings
            and 'AppInfo.displayMachineName' in settings
            and 'licenseManager.expirationDate' in settings
            and 'rememberedKey()' in settings
            and 'ExploitSupportPolicy.verifiedIOS16Range' in settings
            and 'ExploitSupportPolicy.verifiedIOS27Range' in settings,
            "Settings groups device, license and key data with the supported iOS versions, without logo/branding")
    activation = read("ThreeOneOSFive/helpers/LicenseActivationView.swift")
    require('@ObservedObject var manager: LicenseManager' in activation
            and 'manager.activate(key: key)' in activation
            and 'manager.rememberedKey()' in activation
            and 'manager.deactivate()' in activation
            and 'if manager.isActive { onAuthenticated() }' in activation
            and 'IOSKeySession' not in activation
            and 'session.submit' not in activation,
            "new login UI delegates key activation and stored-key state to the existing LicenseManager")
    paste_method = between(activation, "    private func pasteKey() {", "    private func activate() {")
    require('Button(action: pasteKey)' in activation
            and 'UIPasteboard.general.string' in paste_method
            and activation.count('UIPasteboard.general.string') == 1,
            "login reads the clipboard only after the user taps the paste-key button")
    portuguese_activation = [
        "ACESSO LICENCIADO", "EXTERNAL SYSTEM", "Informe sua key para continuar.",
        "Digite sua key iOS", "Lembrar key neste dispositivo",
        "Colar key da área de transferência", "CONTINUAR", "LICENÇA ATIVA",
    ]
    require(all(text in activation for text in portuguese_activation),
            "new activation screen uses the Portuguese SwiftUI login presentation from the source ZIP")
    spanish_activation = [
        "ACCESS PORTAL", "ENTRAR EN FILZA", "Introduce tu key",
        "Recordar key", "ACCEDER AHORA", "JUGADORES ONLINE", "HOURS", "SEC",
    ]
    require(not any(text in activation for text in spanish_activation),
            "activation screen contains none of the previous Spanish labels")
    app_entry = read("ThreeOneOSFive/App.swift")
    license_manager = read("ThreeOneOSFive/helpers/LicenseManager.swift")
    license_client = read("ThreeOneOSFive/helpers/FilzaLicense.swift")
    require(not (ROOT / "ThreeOneOSFive/helpers/LockScreenView.swift").exists()
            and "isLocked" not in app_entry
            and "globalMessage" not in app_entry
            and "refreshRemoteState" not in license_manager
            and "fetchActiveKeysCount" not in license_client,
            "legacy remote lock, global message and old backend methods are absent from the IPA")
    flow_markers = [
        "CalculadoraIPhoneView {",
        "LicenseActivationView(manager: licenseManager)",
        "GameSelectionView {",
        "ContentView()",
    ]
    flow_positions = [app_entry.find(marker) for marker in flow_markers]
    require(all(position >= 0 for position in flow_positions)
            and flow_positions == sorted(flow_positions),
            "app entry presents calculator, current-license login, game selection and dashboard in order")
    game_selection = read("ThreeOneOSFive/views/GameSelectionView.swift")
    require('Text("FF NORMAL")' in game_selection
            and 'Image("FreeFireNormal")' in game_selection
            and "MAX" not in game_selection
            and 'subtitle: "MAX"' not in view
            and 'freefiremax' not in view,
            "entry and dashboard expose only the FF Normal game choice")
    info = plistlib.loads((APP / "Info.plist").read_bytes())
    require(info.get("CFBundleShortVersionString") == "5.0.11"
            and info.get("CFBundleVersion") == "22",
            "source Info.plist has the new version/build required to update the installed app")
    project_settings = read("ThreeOneOSFive.xcodeproj/project.pbxproj")
    require(project_settings.count("CURRENT_PROJECT_VERSION = 22;") == 2
            and project_settings.count("MARKETING_VERSION = 5.0.11;") == 2,
            "both Xcode configurations generate the new version/build")
    require("TutorialsView.swift in Sources" in project_settings
            and "Tutorials folder in Resources" in project_settings,
            "Xcode compiles TutorialsView and copies the Tutorials folder into the app bundle")
    design = read("ThreeOneOSFive/views/DesignSystem.swift")
    require('DragGesture(minimumDistance: 4)' in design
            and 'Arraste para a esquerda' in design
            and 'Arraste para a direita' in design,
            "patch cards retain a real draggable switch")

    anti = read("ThreeOneOSFive/helpers/AntiCrack.swift")
    resource_tests = read("tools/validate_ipa_resources.py")
    require('signatureOffset' in anti
            and '["mov", "mp4", "m4v"].contains(mediaType) ? 4 : 0' in anti,
            "integrity check recognizes ISO-BMFF video ftyp at offset 4")
    require('bundleID == "com.apple.mobile.MobileHouseArrest"' in anti
            and 'Bundle ID divergente — bloqueando interface protegida' in anti
            and 'return appContainerIsValid && resourcesMatch && canonicalBrand' in anti
            and 'if !resourcesMatch' in anti
            and 'recursos críticos alterados — bloqueando interface protegida' in anti,
            "a changed Bundle ID or critical resource is blocked at startup")
    tutorial_specs = [
        "Tutorials/tutorial_error_banner.jpg|jpg|1000|2000000|ffd8ff",
        "Tutorials/tutorial_ffth_banner.jpg|jpg|1000|2000000|ffd8ff",
        "Tutorials/tutorial_ap_banner.jpg|jpg|1000|2000000|ffd8ff",
    ]
    tutorials_view = read("ThreeOneOSFive/TutorialsView.swift")
    require(all(spec in anti for spec in tutorial_specs)
            and 'FileHandle(forReadingFrom: resolvedURL)' in anti
            and 'read(upToCount: signature.count)' in anti
            and 'APPROVED_TUTORIAL_SHA256' in resource_tests
            and 'return remoteItems' in tutorials_view
            and 'tutorial_error_others' not in tutorials_view,
            "tutorial tab contains no bundled videos and only renders validated remote media")
    require('ftyp' in resource_tests and 'offset = 4' in resource_tests,
            "resource validator includes MOV/MP4/M4V ftyp offset-4 test cases")

    icon_path = APP / "Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
    mark_path = APP / "REALExternalMark.png"
    require(icon_path.is_file() and mark_path.is_file()
            and icon_path.read_bytes() != mark_path.read_bytes(),
            "Calculadora app icon is separate from the internal activation artwork")
    print("Security source audit completed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print("FAIL:", exc, file=sys.stderr)
        raise SystemExit(1)
