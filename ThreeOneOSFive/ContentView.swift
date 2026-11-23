import SwiftUI
import UIKit



struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appState: AppState
    @State private var showSettings = false
    @State private var isMenuExpanded = false
    @StateObject private var patchStore = PatchProjectStore.shared
    @StateObject private var onlineCatalog = PatchCatalogStore.shared
    @State private var patchOperationBusy = false
    @State private var pairingRecoveryBusy = false
    @State private var fileAccessMessage: String?
    @State private var fileAccessChecking = false
    @State private var resetInProgress = false
    @State private var patchMessage = "PRONTO — TOQUE EM UM PATCH"
    @State private var activationFailureDetails = ""
    @State private var showActivationFailureAlert = false
    @State private var selectedGameTab: GameTab = .cache
    @State private var activePatchID: UUID?
    @State private var selectionTapLocked = false
    @State private var appliedPatchIDs: Set<UUID> = []
    @State private var showManualRestorePrompt = false
    @State private var selectedMainPage = 0

    enum GameTab: String, CaseIterable {
        case cache = "CACHE"
        case avatar = "AVATAR"
        case skin = "SKIN"
        case external = "EXTERNAL"
        case hologram = "HOLOGRAM"

        var category: PatchCatalog.Category {
            switch self {
            case .cache: return .cache
            case .avatar: return .avatar
            case .skin: return .skin
            case .external: return .external
            case .hologram: return .hologram
            }
        }

        var icon: String {
            switch self {
            case .cache: return "internaldrive.fill"
            case .avatar: return "person.crop.circle.fill"
            case .skin: return "tshirt.fill"
            case .external: return "square.and.arrow.up"
            case .hologram: return "wand.and.stars"
            }
        }

        var displayTitle: String {
            switch self {
            case .cache: return "Cachê"
            case .avatar: return "Avatar"
            case .skin: return "Skin"
            case .external: return "External"
            case .hologram: return "Holograma"
            }
        }

        var gradientColors: [Color] {
            switch self {
            case .cache: return [AppTheme.accent, Color(red: 0.30, green: 0.00, blue: 0.00)]
            case .avatar: return [AppTheme.secondaryAccent, Color(red: 0.42, green: 0.00, blue: 0.00)]
            case .skin: return [AppTheme.cyberBlue, Color(red: 0.03, green: 0.04, blue: 0.14)]
            case .external: return [AppTheme.accent, Color(red: 0.55, green: 0.00, blue: 0.00)]
            case .hologram: return [Color(red: 1.00, green: 0.02, blue: 0.04), Color(red: 0.34, green: 0.00, blue: 0.01)]
            }
        }
    }

    var filteredLocalItems: [PatchLibraryItem] {
        patchStore.items.filter { item in
            matchesSelectedCategory(item)
        }
    }

    private var remotePlaceholderItems: [FilzaLicense.CatalogItem] {
        onlineCatalog.items.filter { remote in
            guard PatchCatalog.Category(remoteFeature: remote.cat) == selectedGameTab.category else { return false }
            return !patchStore.items.contains { $0.packageURL.lastPathComponent == remote.localFilename }
        }
    }

    private func matchesSelectedCategory(_ item: PatchLibraryItem) -> Bool {
        let filename = item.packageURL.lastPathComponent

        if let remote = onlineCatalog.items.first(where: {
            $0.localFilename == filename
        }) {
            return PatchCatalog.Category(remoteFeature: remote.cat) == selectedGameTab.category
        }

        if let directEntry = PatchCatalog.entry(forBundledFile: filename) {
            return directEntry.category == selectedGameTab.category
        }

        return false
    }

    private let persistedPatchIDsKey = "com.hyperregedit.appliedPatchIDs"

    private func restorePersistedPatchIDs() {
        let values = UserDefaults.standard.stringArray(forKey: persistedPatchIDsKey) ?? []
        let stored = Set(values.compactMap(UUID.init(uuidString:)))
        DispatchQueue.global(qos: .utility).async {
            let pending = Set(DevicePatchService.pendingReceipts().map(\.projectID))
            DispatchQueue.main.async {
                guard !self.patchOperationBusy else { return }
                self.appliedPatchIDs = stored.intersection(pending).union(pending)
                self.persistAppliedPatchIDs()
                self.onlineCatalog.syncEnabledStates()
            }
        }
    }

    private func persistAppliedPatchIDs() {
        UserDefaults.standard.set(appliedPatchIDs.map(\.uuidString), forKey: persistedPatchIDsKey)
    }

    private var dashboardPage: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if patchStore.isLoading {
                        HStack(spacing: 8) {
                            ProgressView().tint(AppTheme.secondaryAccent)
                            Text("Carregando patches…")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(AppTheme.panelGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    if shouldShowPairingRecovery {
                        pairingRecoveryPanel
                    }
                    patchSection
                    if showManualRestorePrompt && !isPersistentCategory(selectedGameTab.category) {
                        manualRestorePrompt
                            .id("manualRestorePrompt")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
            .onChange(of: showManualRestorePrompt) { isVisible in
                guard isVisible else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.easeInOut(duration: 0.20)) {
                        proxy.scrollTo("manualRestorePrompt", anchor: .center)
                    }
                }
            }
        }
    }

    private var manualRestorePrompt: some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule().fill(AppTheme.rgbRed).frame(width: 3, height: 76)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppTheme.rgbRed)
                    Text("Restauração manual")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text("Depois da injeção, use este botão para restaurar o original salvo no aparelho.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                if isFreeFireGameTab {
                    Button { forceOriginalFileInSelectedGame() } label: {
                        Label(forceOriginalButtonTitle, systemImage: "arrow.down.doc.fill")
                            .font(.system(size: 12, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(AppTheme.rgbGradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .background(AppTheme.panelGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppTheme.rgbRed.opacity(0.52), lineWidth: 0.9))
    }

    private var menuHeader: some View {
        HStack(spacing: 13) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isMenuExpanded.toggle()
                }
            } label: {
                Image(systemName: isMenuExpanded ? "xmark" : "line.3.horizontal")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.referenceCard, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(AppTheme.signalEdge, lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isMenuExpanded ? "Fechar menu" : "Abrir menu de categorias")

            VStack(alignment: .leading, spacing: 3) {
                Text(selectedMainPage == 0 ? "Patchs" : "Tutoriais")
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text(selectedMainPage == 0 ? selectedGameTab.displayTitle : "Guias disponíveis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.54))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var expandedMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CATEGORIAS")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(AppTheme.secondaryAccent)
                .padding(.bottom, 2)

            ForEach(GameTab.allCases, id: \.self) { tab in
                let selected = selectedMainPage == 0 && selectedGameTab == tab
                Button {
                    guard !selectionTapLocked else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedGameTab = tab
                        selectedMainPage = 0
                        isMenuExpanded = false
                    }
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 22)
                        Text(tab.displayTitle)
                            .font(.system(size: 13, weight: selected ? .bold : .medium, design: .rounded))
                        Spacer()
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(AppTheme.secondaryAccent)
                        }
                    }
                    .foregroundStyle(selected ? .white : .white.opacity(0.76))
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .padding(.horizontal, 11)
                    .background(selected ? AppTheme.accent.opacity(0.16) : AppTheme.consoleBackground.opacity(0.70), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(selected ? AppTheme.accent.opacity(0.42) : Color.white.opacity(0.06), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
            }

            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 0.5).padding(.vertical, 3)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    selectedMainPage = 1
                    isMenuExpanded = false
                }
            } label: {
                Label("Tutoriais", systemImage: "play.rectangle.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.84))
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .padding(.horizontal, 11)
                    .background(AppTheme.consoleBackground.opacity(0.70), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isMenuExpanded = false }
                showSettings = true
            } label: {
                Label("Configurações", systemImage: "gearshape.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.84))
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .padding(.horizontal, 11)
                    .background(AppTheme.consoleBackground.opacity(0.70), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(AppTheme.panelGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppTheme.signalEdge, lineWidth: 0.8))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    var body: some View {
        ZStack {
            ParticleFieldBackground()
            VStack(spacing: 0) {
                menuHeader
                if isMenuExpanded {
                    expandedMenu
                }
                Group {
                    if selectedMainPage == 0 {
                        dashboardPage
                            .transition(.opacity)
                    } else {
                        TutorialsView()
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: selectedMainPage)
        .animation(.easeInOut(duration: 0.18), value: isMenuExpanded)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(item: $patchStore.passwordRequest, onDismiss: patchStore.cancelUnlock) { _ in
            PatchUnlockPrompt(store: patchStore)
        }
        .onAppear {
            // Migrate installations that previously persisted automatic patch mode.
            UserDefaults.standard.set(false, forKey: "filzaBypass.automaticPatchMode")
            restorePersistedPatchIDs()
            patchStore.reload()
            Task { await onlineCatalog.refresh() }
            reconnectSavedAirLiftIfNeeded()
        }
        .onChange(of: scenePhase, perform: { phase in
            if phase == .background {
                BackgroundTaskKeeper.shared.appDidEnterBackground()
                // Keep the verified, hidden session cache so returning to the app
                // does not redownload every package. It remains outside Documents,
                // excluded from backup, protected at rest, and cleared on explicit cleanup.
                patchStore.reload()
                return
            }
            guard phase == .active, !patchOperationBusy else { return }
            BackgroundTaskKeeper.shared.appWillEnterForeground()
            reconnectSavedAirLiftIfNeeded()
            patchStore.reload()
            Task { await onlineCatalog.refresh() }
        })
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                guard !Task.isCancelled else { continue }
                await onlineCatalog.refresh()
            }
        }
        .alert("Falha na operação do patch", isPresented: $showActivationFailureAlert) {
            Button("Copiar detalhes") {
                UIPasteboard.general.string = activationFailureDetails
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(activationFailureDetails)
        }
    }

    // MARK: - Patch Section

    private var patchSection: some View {
        let localItems = filteredLocalItems
        let remoteItems = remotePlaceholderItems

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(selectedGameTab.displayTitle)
                    .font(.system(size: 21, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(localItems.count + remoteItems.count) opções")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.secondaryAccent)
            }

            Text("Ativação manual: toque em um patch para ativar ou desativar.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.63))
                .fixedSize(horizontal: false, vertical: true)

            if let downloadError = onlineCatalog.downloadError {
                Text(downloadError)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.orange.opacity(0.9))
                    .padding(.vertical, 4)
            }

            if localItems.isEmpty && remoteItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nenhum patch nesta categoria")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                    Text("Os patches disponíveis aparecerão aqui.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.48))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 22)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(localItems) { item in
                        patchCardView(for: item)
                    }
                    ForEach(remoteItems, id: \.id) { remote in
                        PremiumPatchCard(
                            name: remote.name,
                            target: selectedGameTab.rawValue,
                            color: AppTheme.accent,
                            isEnabled: onlineCatalog.isEnabled(remote),
                            isPending: false,
                            isBusy: onlineCatalog.activeID != nil || patchOperationBusy,
                            isAvailable: false,
                            isDownloadable: true,
                            previewURL: remote.img
                        ) {
                            // Download/activation/restoration is initiated only by this tap.
                            onlineCatalog.toggle(remote) { message in
                                patchMessage = message
                                patchStore.reload()
                            }
                        }
                    }
                }
            }

            if patchOperationBusy || patchMessage != "PRONTO — TOQUE EM UM PATCH" {
                StatusMessageBar(
                    message: patchMessage,
                    isSuccess: patchMessage.localizedCaseInsensitiveContains("successful"),
                    isBusy: patchOperationBusy
                )
            }
        }
    }

    // MARK: - Helpers

    private func isPackageAvailable(_ item: PatchLibraryItem) -> Bool {
        guard FileManager.default.fileExists(atPath: item.packageURL.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: item.packageURL.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0 else { return false }
        return true
    }

    private func isReadyToSelect(_ item: PatchLibraryItem) -> Bool {
        isPackageAvailable(item) && item.project != nil
    }

    private func isPatchApplied(_ item: PatchLibraryItem) -> Bool {
        // Journal snapshots are loaded off-main. Never wait for a remote write lock during SwiftUI rendering.
        appliedPatchIDs.contains(item.uniqueID)
    }

    private func remoteCatalogItem(for item: PatchLibraryItem) -> FilzaLicense.CatalogItem? {
        let filename = item.packageURL.lastPathComponent
        return onlineCatalog.items.first { remote in
            remote.localFilename == filename
        }
    }

    @ViewBuilder
    private func patchCardView(for item: PatchLibraryItem) -> some View {
        let isPending = false
        let enabled = isPatchApplied(item)
        let busy = patchOperationBusy || onlineCatalog.activeID != nil
        let remote = remoteCatalogItem(for: item)
        PremiumPatchCard(
            name: remote?.name ?? item.displayName,
            target: selectedGameTab.rawValue,
            color: AppTheme.accent,
            isEnabled: enabled,
            isPending: isPending,
            isBusy: busy,
            isAvailable: enabled || isPackageAvailable(item),
            previewURL: remote?.img
        ) {
            if item.isLocked && !isPatchApplied(item) {
                patchStore.requestUnlock(for: item)
            } else {
                toggleLocalPatch(item)
            }
        }
    }
    private func category(for item: PatchLibraryItem) -> PatchCatalog.Category? {
        let filename = item.packageURL.lastPathComponent
        if let remote = onlineCatalog.items.first(where: {
            $0.localFilename == filename
        }) {
            return PatchCatalog.Category(remoteFeature: remote.cat)
        }
        return PatchCatalog.entry(forBundledFile: filename)?.category
    }

    private func isPersistentCategory(_ category: PatchCatalog.Category) -> Bool {
        // Every PatchHub category requires explicit activation and restoration.
        switch category {
        case .cache, .avatar, .skin, .external, .hologram:
            return false
        }
    }

    private var shouldShowPairingRecovery: Bool {
        let v = AppInfo.versionTuple
        let wasNativelyUnsupported = !ExploitSupportPolicy.isSupported(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
        guard wasNativelyUnsupported else { return false }
        let store = AirLiftPairingStore.shared
        return appState.isSupported || store.hasPersistentResetRecoveryAfterPairing
    }

    private var pairingRecoveryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Vai usar outra opção?")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Caso deseje usar outra opção, clique nesse botão, feche e abra a IPA")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
            Button { restoreOriginals(reconnect: true) } label: {
                HStack(spacing: 8) {
                    if pairingRecoveryBusy { ProgressView().tint(.white) }
                    else { Image(systemName: "arrow.triangle.2.circlepath") }
                    Text(pairingRecoveryBusy ? "Reconectando e restaurando…" : "Reconectar e restaurar originais")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
            .disabled(patchOperationBusy || onlineCatalog.activeID != nil)

            Button { checkFileAccess(forceReconnect: false) } label: {
                HStack(spacing: 8) {
                    if fileAccessChecking { ProgressView().tint(.white) }
                    else { Image(systemName: "doc.text.magnifyingglass") }
                    Text(fileAccessChecking ? "Verificando acesso…" : "Verificar acesso aos arquivos")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.secondaryAccent)
            if let fileAccessMessage {
                Text(fileAccessMessage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(fileAccessMessage.hasPrefix("OK") ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button { checkFileAccess(forceReconnect: true) } label: {
                    Label("Reconectar e obter acesso aos arquivos", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                Text("O emparelhamento está salvo, mas a sessão de arquivos ainda não respondeu. Mantenha o LocalDevVPN ligado e toque no botão para tentar novamente.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                resetFromZero()
            } label: {
                HStack(spacing: 8) {
                    if resetInProgress { ProgressView().tint(AppTheme.rgbRed) }
                    else { Image(systemName: "trash.slash") }
                    Text(resetInProgress ? "Resetando e aguardando…" : "Resetar do zero")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.rgbRed)
            // A reset may be requested while the recovery button is still
            // finishing. It is serialized on operationQueue instead of being
            // silently ignored by the old patchOperationBusy guard.
            .disabled(resetInProgress || onlineCatalog.activeID != nil)
        }
        .padding(14)
        .background(AppTheme.panelGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.signalEdge, lineWidth: 0.8))
    }

    private func checkFileAccess(forceReconnect: Bool) {
        guard !fileAccessChecking else { return }
        fileAccessChecking = true
        fileAccessMessage = nil
        DevicePatchService.operationQueue.async {
            do {
                if WorseQueryAccess.isRequired {
                    let bundleID = "com.dts.freefireth"
                    try DevicePatchService.verifyDirectFileAccess(bundleID: bundleID)
                    DispatchQueue.main.async {
                        self.fileAccessMessage = "OK — COM ACESSO AOS ARQUIVOS"
                        self.fileAccessChecking = false
                    }
                    return
                }

                if forceReconnect || AirLiftTransport.shared.state != .connected {
                    guard AirLiftTransport.shared.connectWithRecovery(pin: nil, attempts: 5) else {
                        throw AirLiftTransportError.tunnelUnavailable
                    }
                }
                let target = ("com.dts.freefireth", "Documents/contentcache/Compulsory/ios/gameassetbundles/avatar/assetindexer.U6Zffc4YIR3DslNj3cXvYGAqz58~3D")
                try AirTrafficPatchTransaction.verifyFileAccess(bundleID: target.0, relativePath: target.1)
                DispatchQueue.main.async { self.fileAccessMessage = "OK — COM ACESSO AOS ARQUIVOS"; self.fileAccessChecking = false }
            } catch {
                DispatchQueue.main.async { self.fileAccessMessage = "PAIRING — PAREADO, MAS SEM ACESSO AOS ARQUIVOS\n\(error.localizedDescription)"; self.fileAccessChecking = false }
            }
        }
    }

    private func forceRestoreAll() {
        restoreOriginals(reconnect: false)
    }

    /// Returns this installation to the first-run state without uninstalling.
    private func resetFromZero() {
        guard !resetInProgress, onlineCatalog.activeID == nil else {
            patchMessage = "AGUARDE O RESET ATUAL TERMINAR"
            return
        }
        patchOperationBusy = true
        pairingRecoveryBusy = true
        resetInProgress = true
        activePatchID = nil
        patchMessage = "RESTAURANDO E RESETANDO..."

        DevicePatchService.operationQueue.async {
            let result = DevicePatchService.restorePendingOriginals(reconnect: true)
            DispatchQueue.main.async {
                guard result.failures.isEmpty else {
                    self.patchOperationBusy = false
                    self.pairingRecoveryBusy = false
                    self.resetInProgress = false
                    self.patchMessage = "RESET INCOMPLETO — TENTE NOVAMENTE"
                    self.activationFailureDetails = "Antes de resetar, todos os originais precisam ser confirmados.\n\n" + result.failures.joined(separator: "\n\n")
                    self.showActivationFailureAlert = true
                    return
                }
                DevicePatchService.discardResolvedJournals()
                self.appliedPatchIDs.removeAll()
                self.persistAppliedPatchIDs()
                self.clearTemporaryPatchState()
                self.showManualRestorePrompt = false
                AirLiftPairingStore.shared.clearConnectionConfirmationForThisInstallation()
                AirLiftPairingStore.shared.deletePairingFile()
                AirLiftTransport.shared.disconnect()
                self.patchOperationBusy = false
                self.pairingRecoveryBusy = false
                self.resetInProgress = false
                self.patchMessage = "FECHE E ABRA O EXTERNAL NOVAMENTE PARA PODER USAR OUTRA OPÇÃO"
                self.patchStore.reload()
                self.onlineCatalog.clearEnabledStates()
                self.onlineCatalog.syncEnabledStates()
                self.appState.refreshAirLiftConnectionState()
                // O iOS não permite que uma IPA encerre o próprio processo
                // de forma suportada. O estado abaixo deixa o reset concluído
                // e exige fechar e abrir a IPA para iniciar novamente.
            }
        }
    }

    /// Cancel future timers, but never overlap a write already in progress.
    private func restoreOriginals(reconnect: Bool, onlyIDs: Set<UUID>? = nil) {
        guard !patchOperationBusy, onlineCatalog.activeID == nil else {
            patchMessage = "AGUARDE A OPERAÇÃO ATUAL TERMINAR"
            return
        }
        patchOperationBusy = true
        pairingRecoveryBusy = reconnect
        activePatchID = nil
        patchMessage = reconnect ? "RECONECTANDO E RESTAURANDO..." : "RESTAURANDO ORIGINAIS..."

        DevicePatchService.operationQueue.async {
            let result = DevicePatchService.restorePendingOriginals(reconnect: reconnect, projectIDs: onlyIDs)
            DispatchQueue.main.async {
                if result.failures.isEmpty {
                    if let onlyIDs { self.appliedPatchIDs.subtract(onlyIDs) }
                    else { self.appliedPatchIDs.removeAll() }
                    self.clearTemporaryPatchState()
                    self.showManualRestorePrompt = false
                    self.patchMessage = reconnect
                        ? "CONEXÃO PRONTA — ESCOLHA OUTRO PATCH"
                        : (result.restoredTransactions > 0 ? "ORIGINAIS RESTAURADOS" : "NENHUM PATCH ATIVO")
                } else {
                    self.appliedPatchIDs.subtract(result.restoredIDs)
                    self.appliedPatchIDs.formUnion(result.remainingIDs)
                    self.showManualRestorePrompt = !result.remainingIDs.isEmpty
                    self.patchMessage = "RESTAURAÇÃO INCOMPLETA — TENTE NOVAMENTE"
                    self.activationFailureDetails = "Não foi possível restaurar todos os originais. Os patches pendentes continuam marcados.\n\n" + result.failures.joined(separator: "\n\n")
                    self.showActivationFailureAlert = true
                }
                self.persistAppliedPatchIDs()
                self.patchOperationBusy = false
                self.pairingRecoveryBusy = false
                self.patchStore.reload()
                self.onlineCatalog.syncEnabledStates()
                self.appState.refreshAirLiftConnectionState()
            }
        }
    }

    /// Restores the selected feature-category patches through the manual FF button.
    private func forceRestoreFFOnly() {
        let ffIDs = Set(patchStore.items.compactMap { item -> UUID? in
            guard let itemCategory = category(for: item), !isPersistentCategory(itemCategory) else { return nil }
            return item.uniqueID
        })
        restoreOriginals(reconnect: false, onlyIDs: ffIDs)
    }

    /// Restore the journaled bytes directly, like the Amazon reference IPA.
    /// DevicePatchService restores the AirTraffic connection only when the
    /// actual journal operation needs it, so a stale session does not block
    /// an otherwise valid restore before it starts.
    private func restoreManualOriginalFromDevice() {
        // A recuperação manual deve descobrir o journal real no disco. O
        // conjunto em memória pode ficar desatualizado após reinício ou
        // atualização e, nesse caso, o botão aparecia mas não restaurava nada.
        restoreOriginals(reconnect: true, onlyIDs: nil)
    }

    private var forceOriginalButtonTitle: String {
        "FORÇAR ARQUIVO NO FREE FIRE"
    }

    private var isFreeFireGameTab: Bool {
        true
    }

    private func forceOriginalFileInSelectedGame() {
        guard isFreeFireGameTab, !patchOperationBusy, onlineCatalog.activeID == nil else {
            patchMessage = "AGUARDE A OPERAÇÃO ATUAL TERMINAR"
            return
        }
        let bundleID = "com.dts.freefireth"
        let gameName = "FREE FIRE"
        patchOperationBusy = true
        pairingRecoveryBusy = true
        patchMessage = "FORZANDO ARCHIVO EN \(gameName)..."
        DevicePatchService.operationQueue.async {
            var lastError: Error?
            var completed = false
            for attempt in 1...8 {
                do {
                    try DevicePatchService.forceOriginalForCurrentBackend(bundleID: bundleID)
                    completed = true
                    break
                } catch {
                    lastError = error
                    if attempt < 8 { Thread.sleep(forTimeInterval: 0.6) }
                }
            }
            DispatchQueue.main.async {
                self.patchOperationBusy = false
                self.pairingRecoveryBusy = false
                if completed {
                    self.patchMessage = "COMPLETADO — ARCHIVO FORZADO EN \(gameName)"
                } else {
                    self.patchMessage = "NO COMPLETADO — NO SE CONFIRMÓ EL ARCHIVO"
                    self.activationFailureDetails = lastError?.localizedDescription ?? "No fue posible confirmar la escritura."
                    self.showActivationFailureAlert = true
                }
            }
        }
    }

    private func toggleLocalPatch(_ item: PatchLibraryItem) {
        guard !patchOperationBusy, onlineCatalog.activeID == nil, !selectionTapLocked,
              isPatchApplied(item) || isReadyToSelect(item) else {
            patchMessage = "AGUARDE O CARREGAMENTO DO PATCH TERMINAR"
            return
        }
        selectionTapLocked = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            selectionTapLocked = false
        }
        let wasApplied = isPatchApplied(item)
        let selectedCategory = category(for: item) ?? selectedGameTab.category

        if !wasApplied && !appliedPatchIDs.isEmpty {
            patchMessage = "RESETE DO ZERO ANTES DE USAR OUTRO PATCH"
            showManualRestorePrompt = false
            return
        }

        if !wasApplied {
            // A troca exige o reset explícito para evitar journals antigos e
            // garantir que o próximo patch comece em estado limpo.
            let previousSameCategoryItems = patchStore.items.filter { candidate in
                candidate.uniqueID != item.uniqueID &&
                category(for: candidate) == selectedCategory &&
                isPatchApplied(candidate)
            }

            patchOperationBusy = true
            activePatchID = item.uniqueID
            patchMessage = "PROCESSANDO..."

            DevicePatchService.operationQueue.async {
                var inactiveIDs = Set<UUID>()
                var restoreFailure: String?
                if !isPersistentCategory(selectedCategory) {
                    let previousIDs = Set(previousSameCategoryItems.map(\.uniqueID))
                    // Do not make an empty recovery reconnect gate the first
                    // manual apply. Reconnect only when there is an older
                    // patch that actually needs restoration.
                    if !previousIDs.isEmpty {
                        let recovery = DevicePatchService.restorePendingOriginals(
                            reconnect: true,
                            projectIDs: previousIDs
                        )
                        if recovery.failures.isEmpty {
                            inactiveIDs.formUnion(previousIDs.subtracting(recovery.remainingIDs))
                        } else {
                            restoreFailure = recovery.failures.joined(separator: "\n\n")
                        }
                    }
                }

                var message: String
                if let restoreFailure {
                    message = "ERROR — " + restoreFailure
                } else {
                    do {
                        var project = item.project!
                        project.id = item.uniqueID
                        _ = try DevicePatchService.apply(project: project)
                        message = "ATIVO — " + item.displayName
                    } catch {
                        message = "ERROR — " + error.localizedDescription
                    }
                }

                DispatchQueue.main.async { [self] in
                    appliedPatchIDs.subtract(inactiveIDs)
                    if message.hasPrefix("ATIVO") {
                        appliedPatchIDs.insert(item.uniqueID)
                        if !isPersistentCategory(selectedCategory) {
                            showManualRestorePrompt = true
                        }
                        PatchAudioFeedback.bypassActivated()
                    }
                    persistAppliedPatchIDs()
                    patchMessage = message.hasPrefix("ATIVO") ? "PATCH ATIVO" : "NÃO FOI POSSÍVEL ATIVAR"
                    if !message.hasPrefix("ATIVO") {
                        activationFailureDetails = message.replacingOccurrences(of: "ERROR — ", with: "")
                        showActivationFailureAlert = true
                    }
                    if !message.hasPrefix("ATIVO") { showManualRestorePrompt = false }
                    patchOperationBusy = false
                    activePatchID = nil
                }
            }
            return
        }

        // Já aplicado? Desliga agora.
        if wasApplied {
            patchOperationBusy = true
            activePatchID = item.uniqueID
            patchMessage = "PROCESSANDO..."
            DevicePatchService.operationQueue.async {
                var message: String
                if let receipt = DevicePatchService.latestReceipt(projectID: item.uniqueID) {
                    do {
                        try DevicePatchService.restore(receipt: receipt, allowModifiedPatchedFiles: true)
                        message = "RESTORE SUCCESSFUL"
                    } catch {
                        message = "ERROR — \(error.localizedDescription)"
                    }
                } else {
                    message = "RESTORE SUCCESSFUL — NO ACTIVE JOURNAL"
                }
                DispatchQueue.main.async {
                    self.patchMessage = message.lowercased().contains("successful")
                        ? "PATCH DESATIVADO"
                        : "NÃO FOI POSSÍVEL DESATIVAR"
                    if message.lowercased().contains("successful") {
                        PatchAudioFeedback.originalRestored()
                        self.appliedPatchIDs.remove(item.uniqueID)
                        self.persistAppliedPatchIDs()
                        self.showManualRestorePrompt = false
                    }
                    if !message.lowercased().contains("successful") {
                        self.activationFailureDetails = message.replacingOccurrences(of: "ERROR — ", with: "")
                        self.showActivationFailureAlert = true
                    }
                    self.onlineCatalog.syncEnabledStates()
                    self.patchOperationBusy = false
                    self.activePatchID = nil
                }
            }
            return
        }

    }

    private func clearTemporaryPatchState() {
        UserDefaults.standard.removeObject(forKey: "temporaryPatchID")
        UserDefaults.standard.removeObject(forKey: "temporaryPatchRestoreDeadline")
    }

    private func reconnectSavedAirLiftIfNeeded() {
        guard !patchOperationBusy,
              AirLiftPairingStore.shared.hasPairingFile else { return }
        DispatchQueue.global(qos: .utility).async {
            let connected = AirLiftTransport.shared.reconnectSavedPairingIfNeeded()
            DispatchQueue.main.async {
                guard connected else { return }
                // A saved pairing plus an active LocalDevVPN is enough to
                // restore compatibility on the next launch; no second manual
                // pairing action is needed.
                AirLiftPairingStore.shared.markConnectionConfirmedForThisInstallation()
                self.appState.refreshAirLiftConnectionState()
            }
        }
    }

    private func openGame(scheme: String) {
        guard !patchOperationBusy, onlineCatalog.activeID == nil,
              let url = URL(string: "\(scheme)://") else { return }
        UIApplication.shared.open(url, options: [:]) { success in
            log("launch: \(scheme) success=\(success)")
        }
    }
}

// Os callbacks permanecem sem efeito para preservar a sequência dos handlers.
private enum PatchAudioFeedback {
    static func bypassActivated() {}
    static func originalRestored() {}
}
