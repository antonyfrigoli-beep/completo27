import SwiftUI
import AVKit
import AVFoundation
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
private struct TutorialCatalog: Codable { let catalogVersion: Int; let tutorials: [RemoteTutorial] }

private final class TutorialRemoteStore: ObservableObject {
    @Published private(set) var items: [RemoteTutorial] = []
    @Published private(set) var isRefreshing = false
    private let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PatchHubTutorials", isDirectory: true)
    private let allowedHost = FilzaLicense.patchHubBaseURL.host ?? "painel.proxysystem.org"
    private var timer: Timer?

    init() {
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        loadCachedCatalog()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in Task { await self?.refresh() } }
        Task { await refresh() }
    }
    deinit { timer?.invalidate() }

    func refresh() async {
        guard !isRefreshing else { return }
        await MainActor.run { isRefreshing = true }
        defer { Task { @MainActor in self.isRefreshing = false } }
        var request = URLRequest(url: FilzaLicense.patchHubBaseURL.appendingPathComponent("api/mobile/tutorials"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            let catalog = try JSONDecoder().decode(TutorialCatalog.self, from: data)
            let valid = catalog.tutorials.filter { validateMetadata($0) }
            for tutorial in valid { await downloadIfNeeded(tutorial) }
            let validIDs = Set(valid.map(\.id))
            for file in (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "mp4" && !validIDs.contains(file.deletingPathExtension().lastPathComponent) { try? FileManager.default.removeItem(at: file) }
            await MainActor.run { items = valid.sorted { $0.sortOrder < $1.sortOrder }; saveCatalog(catalog) }
        } catch { /* mantém o último catálogo/cache e fallback local */ }
    }

    func fileURL(for item: RemoteTutorial) -> URL? {
        let url = cache.appendingPathComponent(item.id).appendingPathExtension("mp4")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func validateMetadata(_ item: RemoteTutorial) -> Bool {
        guard let url = URL(string: item.videoURL), url.scheme == "https", url.host == allowedHost,
              item.videoSize > 0, item.videoSize <= 250 * 1024 * 1024,
              item.videoSHA256.count == 64, item.mimeType.hasPrefix("video/") else { return false }
        return true
    }
    private func loadCachedCatalog() {
        let url = cache.appendingPathComponent("catalog.json")
        guard let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(TutorialCatalog.self, from: data) else { return }
        items = catalog.tutorials.filter { validateMetadata($0) }.sorted { $0.sortOrder < $1.sortOrder }
    }
    @MainActor private func saveCatalog(_ catalog: TutorialCatalog) { try? JSONEncoder().encode(catalog).write(to: cache.appendingPathComponent("catalog.json"), options: .completeFileProtection) }
    private func downloadIfNeeded(_ item: RemoteTutorial) async {
        let destination = cache.appendingPathComponent(item.id).appendingPathExtension("mp4")
        if let data = try? Data(contentsOf: destination), data.count == item.videoSize && sha256(data) == item.videoSHA256 && hasAudio(destination) { return }
        guard let url = URL(string: item.videoURL) else { return }
        do {
            let (temporary, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data = try? Data(contentsOf: temporary), data.count == item.videoSize, sha256(data) == item.videoSHA256, hasAudio(temporary) else { return }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch { }
    }
    private func hasAudio(_ url: URL) -> Bool { AVAsset(url: url).tracks(withMediaType: .audio).isEmpty == false }
    private func sha256(_ data: Data) -> String { SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined() }
}

struct TutorialsView: View {
    @StateObject private var remote = TutorialRemoteStore()
    @State private var selectedTutorial: TutorialItem?
    private var tutorials: [TutorialItem] {
        let remoteItems = remote.items.compactMap { item -> TutorialItem? in guard let url = remote.fileURL(for: item) else { return nil }; return TutorialItem(id: item.id, title: item.title, subtitle: item.subtitle, localURL: url, thumbnail: nil, icon: "play.rectangle.fill") }
        if !remoteItems.isEmpty { return remoteItems }
        return [
            TutorialItem(id: "others", title: "Erro em Outros", subtitle: "Como resolver", localURL: Bundle.main.url(forResource: "tutorial_error_others", withExtension: "mov", subdirectory: "Tutorials"), thumbnail: "tutorial_error_banner", icon: "exclamationmark.triangle.fill"),
            TutorialItem(id: "ffth-ffmax", title: "FFTH e FFMax", subtitle: "Como jogar", localURL: Bundle.main.url(forResource: "tutorial_ffth_ffmax", withExtension: "mov", subdirectory: "Tutorials"), thumbnail: "tutorial_ffth_banner", icon: "flame.fill"),
            TutorialItem(id: "ap", title: "Opções AP", subtitle: "Como usar", localURL: Bundle.main.url(forResource: "tutorial_ap", withExtension: "mov", subdirectory: "Tutorials"), thumbnail: "tutorial_ap_banner", icon: "shield.lefthalf.filled")
        ]
    }
    var body: some View {
        ScrollView(showsIndicators: false) { VStack(alignment: .leading, spacing: 16) { Text("Escolha um dos guias para assistir.").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.62)); LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) { ForEach(tutorials) { tutorial in TutorialCard(item: tutorial) { selectedTutorial = tutorial } } }; Text("Toque em um cartão para assistir em tela cheia.").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.48)).frame(maxWidth: .infinity, alignment: .center) }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 24) }
        .fullScreenCover(item: $selectedTutorial) { TutorialPlayerView(item: $0) }
        .task { await remote.refresh() }
    }
}

private struct TutorialItem: Identifiable { let id: String; let title: String; let subtitle: String; let localURL: URL?; let thumbnail: String?; let icon: String }
private struct TutorialCard: View {
    let item: TutorialItem; let action: () -> Void
    var body: some View { Button(action: action) { VStack(alignment: .leading, spacing: 10) { ZStack { if let thumbnail = item.thumbnail, let path = Bundle.main.path(forResource: thumbnail, ofType: "jpg", inDirectory: "Tutorials"), let image = UIImage(contentsOfFile: path) { Image(uiImage: image).resizable().scaledToFill() } else { Color.black; Image(systemName: item.icon).font(.system(size: 24, weight: .black)).foregroundStyle(.white.opacity(0.82)) }; LinearGradient(colors: [Color.black.opacity(0.08), Color.black.opacity(0.48)], startPoint: .top, endPoint: .bottom); Image(systemName: "play.circle.fill").font(.system(size: 31, weight: .bold)).foregroundStyle(.white.opacity(0.94) }.frame(maxWidth: .infinity, minHeight: 116).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)); VStack(alignment: .leading, spacing: 3) { Text(item.title).font(.system(size: 13, weight: .black, design: .rounded)).foregroundStyle(.white).lineLimit(1); Text(item.subtitle).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.58)) } }.padding(10).background(AppTheme.referenceCard, in: RoundedRectangle(cornerRadius: 15, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1)) }.buttonStyle(.plain) }
}
private struct TutorialPlayerView: View {
    let item: TutorialItem; @Environment(\.dismiss) private var dismiss; @State private var player: AVPlayer?
    var body: some View { ZStack(alignment: .topTrailing) { Color.black.ignoresSafeArea(); if let player { VideoPlayer(player: player).ignoresSafeArea().onDisappear { player.pause() } } else { ProgressView().tint(.white) }; Button { player?.pause(); dismiss() } label: { Image(systemName: "xmark").font(.system(size: 15, weight: .black)).foregroundStyle(.white).frame(width: 38, height: 38).background(Color.black.opacity(0.62), in: Circle()) }.buttonStyle(.plain).padding(.top, 18).padding(.trailing, 16) }.onAppear { guard let url = item.localURL else { return }; player = AVPlayer(url: url); player?.play() } }
}
