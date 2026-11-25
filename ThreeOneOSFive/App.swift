import SwiftUI
import UIKit

@main
struct ThreeOneOSFiveApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var licenseManager = LicenseManager()
    @StateObject private var patchDraftCoordinator = PatchDraftCoordinator()
    @StateObject private var fileOperationCoordinator = FileOperationCoordinator();
	@AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
	@AppStorage("filza.appearance") private var appearance = "system"
    @State private var updateOffer: AppUpdateChecker.Offer?
    @State private var calculatorUnlocked = false
    @State private var hasAuthenticated = false
    @State private var hasSelectedGame = false
    @State private var securityBlocked: Bool
    @Environment(\.scenePhase) private var scenePhase

    init() {
        setupLogCapture()
        log("app: FILZA EXTERNAL BYPASS launching — iOS \(AppInfo.osVersion) (\(AppInfo.osBuild)) \(AppInfo.machineName)")
        let blocked = !AntiCrack.verifyAtLaunch()
        _securityBlocked = State(initialValue: blocked)
        // GATE ANTI-CRACK: se o bundle foi modificado ou há debugger/injeção,
        // a interface protegida não é criada. (AntiCrack.swift)
        if blocked {
            log("anticrack: app bloqueado no boot")
        }
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .english
    }

    private func checkForUpdate() {
        Task {
            guard let offer = await AppUpdateChecker.check() else { return }
            await MainActor.run { updateOffer = offer }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if securityBlocked {
                    SecurityBlockedView()
                } else if licenseManager.isLocked {
                    LockScreenView(manager: licenseManager)
                        .environmentObject(licenseManager)
                } else if !calculatorUnlocked {
                    CalculadoraIPhoneView {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            calculatorUnlocked = true
                        }
                    }
                } else if !hasAuthenticated || !licenseManager.isActive {
                    LicenseActivationView(manager: licenseManager) {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            hasAuthenticated = true
                            hasSelectedGame = false
                        }
                    }
                } else if !hasSelectedGame {
                    GameSelectionView {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            hasSelectedGame = true
                        }
                    }
                } else {
                    ContentView()
                        .environmentObject(licenseManager)
                }
                }
                .environmentObject(appState)
                .environmentObject(patchDraftCoordinator)
                .environmentObject(fileOperationCoordinator)
                .environment(\.appLanguage, language)
                .environment(\.locale, language.locale)
            .alert(item: $updateOffer) { offer in
                Alert(
                    title: Text(offer.title),
                    message: Text("\(offer.message)\n\nVersão alvo: \(offer.version) · build \(offer.build)"),
                    primaryButton: .default(Text("Baixar atualização")) {
                        UIApplication.shared.open(offer.url)
                    },
                    secondaryButton: .cancel(Text("Agora não"))
                )
            }
            .alert("Aviso global", isPresented: Binding(
                get: { licenseManager.globalMessage?.isEmpty == false },
                set: { visible in
                    if !visible { licenseManager.dismissGlobalMessage() }
                }
            )) {
                Button("OK") { licenseManager.dismissGlobalMessage() }
            } message: {
                Text(licenseManager.globalMessage ?? "")
            }
            .onAppear {
                guard !securityBlocked else { return }
                licenseManager.beginLaunchSession()
                appState.detectSupport()
                checkForUpdate()
            }
            .onReceive(NotificationCenter.default.publisher(for: .appUpdateChanged)) { _ in
                guard !securityBlocked else { return }
                checkForUpdate()
            }
            .task {
                await AppUpdateChecker.listenForChanges()
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 300_000_000_000)
                    guard !Task.isCancelled else { continue }
                    checkForUpdate()
                }
            }
            .onChange(of: licenseManager.isActive) { isActive in
                if !isActive {
                    hasAuthenticated = false
                    hasSelectedGame = false
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .background {
                    BackgroundTaskKeeper.shared.appDidEnterBackground()
                } else if phase == .active {
                    BackgroundTaskKeeper.shared.appWillEnterForeground()
                    if !AntiCrack.verifyAtLaunch() {
                        securityBlocked = true
                        return
                    }
                    licenseManager.beginLaunchSession()
                    appState.detectSupport()
                    checkForUpdate()
                    // ContentView owns the foreground reconnect so the app
                    // does not start a second handshake in parallel with the
                    // screen-level lifecycle callback.
                }
            }
            .onOpenURL { url in
                guard url.scheme?.lowercased() != "airliftreturn" else { return }
                patchDraftCoordinator.presentImport(url)
            }
	            .preferredColorScheme(preferredColorScheme)
        }
    }

	private var preferredColorScheme: ColorScheme? {
		switch appearance {
		case "light": return .light
		case "dark": return .dark
		default: return nil
		}
	}
}

private struct SecurityBlockedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 52))
                .foregroundStyle(.red)
            Text("Security verification failed")
                .font(.headline)
            Text("This installation was modified or could not be verified.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(28)
		.accessibilityElement(children: .combine)
    }
}

// MARK: - Background Task Keeper
//
// Holds a background + interactive task while the app is in the background so
// the iOS scheduler does not suspend the process mid-injection. Works on all
// supported iOS versions (16+); on older devices the interactive task is the
// one that actually keeps the runloop alive.
//
// Strategy:
//   - beginBackgroundTask gives ~30s of execution time.
//   - beginInteractiveTask (iOS 16+) keeps the runloop alive indefinitely
//     while the task is held.
//   - A 5-second keepalive tick prevents the runloop from idling out.
//   - isIdleTimerDisabled keeps the screen awake so the user can watch progress.
final class BackgroundTaskKeeper {
    static let shared = BackgroundTaskKeeper()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var interactiveTask: UIBackgroundTaskIdentifier = .invalid
    private var keepaliveTimer: Timer?
    private var isInBackground = false

    private init() {}

    func appDidEnterBackground() {
        guard !isInBackground else { return }
        isInBackground = true
        log("bgkeep: entering background — holding tasks for injection")

        // Begin background task (~30s window)
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "REAL.keepalive") { [weak self] in
            log("bgkeep: background task expired by system")
            self?.endBackgroundTask()
        }

        // UIApplication has no public interactive-task API; the background task above
        // is the supported lifecycle mechanism and remains the only task started here.

        // Keep screen awake
        UIApplication.shared.isIdleTimerDisabled = true

        // Keepalive tick every 5s — keeps runloop busy, prevents suspension
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            log("bgkeep: keepalive tick (tasks still held)")
        }
    }

    func appWillEnterForeground() {
        guard isInBackground else { return }
        isInBackground = false
        log("bgkeep: entering foreground — releasing tasks")
        endBackgroundTask()
        endInteractiveTask()
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func endInteractiveTask() {
        // Kept as a lifecycle hook for callers; no public interactive-task API exists.
        interactiveTask = .invalid
    }
}

class AppState: ObservableObject {
    @Published var exploitStatus: ExploitStatus = .notStarted
    @Published var airliftActive = false
    @Published var airliftNeedsSetup = false
    @Published var unsupportedMessage: String?
    @Published var kernelExploitRunning = false

    private var autoRunAttempted = false
    private var savedPairingReconnectInFlight = false

    var kernelExploitApplicable: Bool {
        KernelExploit.isApplicable(
            major: AppInfo.versionTuple.major,
            minor: AppInfo.versionTuple.minor,
            patch: AppInfo.versionTuple.patch,
            build: AppInfo.osBuild
        )
    }

    var isSupported: Bool { unsupportedMessage == nil || airliftActive }

    func detectSupport() {
        let v = AppInfo.versionTuple
        let supported = ExploitSupportPolicy.isSupported(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-access") {
            exploitStatus = .success(method: "Simulator preview")
        }
#endif

        unsupportedMessage = supported ? nil : "iOS \(AppInfo.osVersion) (\(AppInfo.osBuild))"
        if let unsupportedMessage {
            let store = AirLiftPairingStore.shared
            let hasSavedPairing = store.hasPairingFile
            // Não apague o estado compatível enquanto o pairing salvo está
            // sendo reaberto. Antes, a tela piscava para “não suportado” e
            // algumas operações começavam antes do túnel voltar.
            if AirLiftTransport.shared.state == .connected {
                airliftActive = true
                store.markConnectionConfirmedForThisInstallation()
                exploitStatus = .success(method: "Conexão remota")
            } else if !hasSavedPairing || !store.hasConfirmedConnectionForThisInstallation {
                airliftActive = false
                exploitStatus = .unsupported(unsupportedMessage)
            }
            airliftNeedsSetup = !hasSavedPairing
            if hasSavedPairing {
                reconnectSavedPairingAutomatically()
            }
            return
        }

        let applicable = KernelExploit.isApplicable(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
        if applicable {
            refreshKernelExploitStatus()
            maybeAutoRunKernelExploit()
        }

    }

    private func maybeAutoRunKernelExploit() {
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed,
              !autoRunAttempted else { return }
        autoRunAttempted = true
        log("app: starting kernel exploit automatically")
        runKernelExploitIfNeeded()
    }

    private func refreshKernelExploitStatus() {
        guard !kernelExploitRunning else { return }

        // iOS < 26: kernel R/W success persists (no sandbox probe)
        // iOS >= 26: verify full sandbox escape is still active
        if KernelExploit.requiresSandboxEscape {
            if KernelExploit.hasSandboxAccess() {
                if !exploitStatus.isSuccess {
                    exploitStatus = .success(method: KernelExploit.methodName)
                    log("app: existing sandbox access is still active; skipping kernel exploit")
                }
            } else if exploitStatus.isSuccess {
                exploitStatus = .notStarted
                log("app: sandbox access is no longer active")
            }
        }
    }

    private func reconnectSavedPairingAutomatically() {
        guard !savedPairingReconnectInFlight else { return }
        savedPairingReconnectInFlight = true
        DispatchQueue.global(qos: .utility).async {
            let connected = AirLiftTransport.shared.reconnectSavedPairingIfNeeded()
            DispatchQueue.main.async {
                self.savedPairingReconnectInFlight = false
                if connected {
                    self.refreshAirLiftConnectionState()
                }
            }
        }
    }

    func refreshAirLiftConnectionState() {
        let connected = AirLiftTransport.shared.state == .connected
        airliftActive = connected
        airliftNeedsSetup = !connected && !AirLiftPairingStore.shared.hasPairingFile
        if connected {
            exploitStatus = .success(method: "Conexão remota")
        } else if AirLiftPairingStore.shared.hasPairingFile && exploitStatus.isSuccess {
            // O RSD pode oscilar durante a recuperação do túnel. Não trocar
            // um AirLift já estabelecido para “não suportado” nessa janela.
            return
        } else if let unsupportedMessage {
            exploitStatus = .unsupported(unsupportedMessage)
        }
    }

    func runKernelExploitIfNeeded() {
        refreshKernelExploitStatus()
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed else { return }
        kernelExploitRunning = true
        exploitStatus = .notStarted
        log("app: running kernel exploit on background...")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = KernelExploit.run()
            DispatchQueue.main.async {
                self.kernelExploitRunning = false
                if ok {
                    self.exploitStatus = .success(method: KernelExploit.methodName)
                    if KernelExploit.requiresSandboxEscape {
                        log("app: kernel exploit success — sandbox access verified")
                    } else {
                        log("app: kernel exploit success — kernel access active")
                    }
                } else {
                    self.exploitStatus = .failed(method: KernelExploit.methodName, code: -1)
                    log("app: kernel exploit failed — relaunch the app before retrying")
                }
            }
        }
    }
}
