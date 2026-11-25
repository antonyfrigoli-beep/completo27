import SwiftUI
import AVKit
import UIKit
import CryptoKit

private struct RemoteTutorial: Codable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let category: String
    let videoURL: String
    let videoFilename: String
    let videoSize: Int
    let videoSHA256: String
    let mimeType: String
    let sortOrder: Int
    let catalogVersion: Int
    let updatedAt: String?
}

private struct TutorialCatalog: Codable {
    let catalogVersion: Int
    let tutorials: [RemoteTutorial]
}

private final class TutorialRemoteStore: ObservableObject {
    @Published private(set) var items: [RemoteTutorial] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    private let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PatchHubTutorials", isDirectory: true)
    private let allowedHost = FilzaLicense.patchHubBaseURL.host ?? "painel.proxysystem.org"
    private var refreshTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var timer: Timer?

    init() {
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        loadCachedCatalog()
        refreshTask = Task { [weak self] in await self?.refresh() }
        streamTask = Task { [weak self] in await self?.listenForChanges() }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    deinit {
        refreshTask?.cancel()
        streamTask?.cancel()
        timer?.invalidate()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var request = URLRequest(url: FilzaLicense.patchHubBaseURL.appendingPathComponent("api/mobile/tutorials"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                errorMessage = "Resposta inválida do PatchHub."
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                errorMessage = "O PatchHub respondeu HTTP \(http.statusCode)."
                return
            }
            let catalog = try JSONDecoder().decode(TutorialCatalog.self, from: data)
            let valid = catalog.tutorials.filter { validateMetadata($0) }
            items = valid.sorted { $0.sortOrder < $1.sortOrder }
            saveCatalog(catalog)
            var failedDownloads = 0
            for tutorial in valid {
                if !(await downloadIfNeeded(tutorial)) { failedDownloads += 1 }
            }
            let validIDs = Set(valid.map(\.id))
            for file in (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "mp4" && !validIDs.contains(file.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
            if failedDownloads > 0 {
                errorMessage = "Não foi possível baixar \(failedDownloads) vídeo(s). Verifique a conexão e toque em tentar novamente."
            } else if valid.isEmpty {
                errorMessage = nil
            } else {
                errorMessage = nil
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Não foi possível atualizar os tutoriais. Tente novamente em instantes."
            log("tutorial catalog refresh failed: \(error.localizedDescription)")
        }
    }

    private func listenForChanges() async {
        let endpoint = FilzaLicense.patchHubBaseURL.appendingPathComponent("api/mobile/tutorials/events")
        while !Task.isCancelled {
            do {
                var request = URLRequest(url: endpoint)
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 0
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                var hasEvent = false
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    if line.hasPrefix("event: tutorial") || line.hasPrefix("event: ready") {
                        hasEvent = true
                    } else if line.isEmpty && hasEvent {
                        hasEvent = false
                        await refresh()
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                log("tutorial SSE disconnected: \(error.localizedDescription)")
            }
            if !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func fileURL(for item: RemoteTutorial) -> URL? {
        let url = cache.appendingPathComponent(item.id).appendingPathExtension("mp4")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func validateMetadata(_ item: RemoteTutorial) -> Bool {
        guard let url = URL(string: item.videoURL),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == allowedHost.lowercased(),
              item.videoSize > 0,
              item.videoSize <= 250 * 1024 * 1024,
              item.videoSHA256.count == 64,
              item.mimeType.hasPrefix("video/") else { return false }
        return true
    }

    private func loadCachedCatalog() {
        let url = cache.appendingPathComponent("catalog.json")
        guard let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(TutorialCatalog.self, from: data) else { return }
        items = catalog.tutorials.filter { validateMetadata($0) }.sorted { $0.sortOrder < $1.sortOrder }
    }

    private func saveCatalog(_ catalog: TutorialCatalog) {
        do {
            let data = try JSONEncoder().encode(catalog)
            try data.write(to: cache.appendingPathComponent("catalog.json"), options: .completeFileProtection)
        } catch {
            log("tutorial catalog cache write failed: \(error.localizedDescription)")
        }
    }

    private func downloadIfNeeded(_ item: RemoteTutorial) async -> Bool {
        let destination = cache.appendingPathComponent(item.id).appendingPathExtension("mp4")
        if let data = try? Data(contentsOf: destination),
           data.count == item.videoSize,
           sha256(data) == item.videoSHA256 {
            return true
        }
        guard let url = URL(string: item.videoURL) else { return false }
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 600
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (temporary, response) = try await session.download(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  http.url?.scheme?.lowercased() == "https",
                  http.url?.host?.lowercased() == allowedHost.lowercased() else {
                throw URLError(.badServerResponse)
            }
            let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
            guard data.count == item.videoSize, sha256(data) == item.videoSHA256 else {
                throw URLError(.cannotDecodeContentData)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return true
        } catch {
            log("tutorial download failed for \(item.id): \(error.localizedDescription)")
            return false
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct TutorialsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var remote = TutorialRemoteStore()
    @State private var selectedTutorial: TutorialItem?

    private var remoteItems: [TutorialItem] {
        remote.items.compactMap { item in
            guard let url = URL(string: item.videoURL) else { return nil }
            return TutorialItem(id: item.id, title: item.title, subtitle: item.subtitle, localURL: url, thumbnail: nil, icon: "play.rectangle.fill")
        }
    }

    private var tutorials: [TutorialItem] {
        return remoteItems
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                Text(tutorials.isEmpty ? "Nenhum tutorial publicado no momento." : "Escolha um dos guias para assistir.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                if let error = remote.errorMessage {
                    VStack(spacing: 8) {
                        Text(error).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.orange)
                        Button("Tentar novamente") { Task { await remote.refresh() } }
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                }
                if tutorials.isEmpty {
                    Text("Novos vídeos aparecerão aqui assim que forem publicados no PatchHub.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))
                        .frame(maxWidth: .infinity, minHeight: 150)
                        .multilineTextAlignment(.center)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(tutorials) { tutorial in
                            TutorialCard(item: tutorial) { selectedTutorial = tutorial }
                        }
                    }
                    Text("Toque em um cartão para assistir em tela cheia.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .fullScreenCover(item: $selectedTutorial) { TutorialPlayerView(item: $0) }
        .task { await remote.refresh() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await remote.refresh() } }
        }
    }
}

private struct TutorialItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let localURL: URL?
    let thumbnail: String?
    let icon: String
}

private struct TutorialCard: View {
    let item: TutorialItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    Color.black
                    Image(systemName: item.icon).font(.system(size: 24, weight: .black)).foregroundStyle(.white.opacity(0.82))
                    LinearGradient(colors: [Color.black.opacity(0.08), Color.black.opacity(0.48)], startPoint: .top, endPoint: .bottom)
                    Image(systemName: "play.circle.fill").font(.system(size: 31, weight: .bold)).foregroundStyle(.white.opacity(0.94))
                }
                .frame(maxWidth: .infinity, minHeight: 116)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 13, weight: .black, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                    Text(item.subtitle).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.58))
                }
            }
            .padding(10)
            .background(AppTheme.referenceCard, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct TutorialPlayerView: View {
    let item: TutorialItem
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player).ignoresSafeArea().onDisappear { player.pause() }
            } else {
                ProgressView().tint(.white)
            }
            Button { player?.pause(); dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .black)).foregroundStyle(.white)
                    .frame(width: 38, height: 38).background(Color.black.opacity(0.62), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            .padding(.trailing, 16)
        }
        .onAppear { guard let url = item.localURL else { return }; player = AVPlayer(url: url); player?.play() }
    }
}
