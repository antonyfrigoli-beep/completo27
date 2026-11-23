import Foundation

enum PatchCatalog {

    enum Category: String, CaseIterable {
        case cache = "CACHE"
        case avatar = "AVATAR"
        case skin = "SKIN"
        case external = "EXTERNAL"
        case hologram = "HOLOGRAM"

        init?(remoteFeature: String?) {
            guard let feature = remoteFeature?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(), !feature.isEmpty else {
                return nil
            }

            switch feature {
            case "cache", "cachê": self = .cache
            case "avatar": self = .avatar
            case "skin": self = .skin
            case "external": self = .external
            case "hologram", "holograma", "hologramas": self = .hologram
            default: return nil
            }
        }

        var remoteFeature: String {
            rawValue.lowercased()
        }
    }

    struct Entry: Identifiable {
        let id: Int
        let filename: String
        let displayName: String
        let category: Category
    }

    // Patch packages are supplied by the PatchHub online catalog.
    static let entries: [Entry] = []

    static func entry(forBundledFile filename: String) -> Entry? {
        if let match = entries.first(where: { $0.filename == filename }) {
            return match
        }
        if !filename.hasSuffix(".3105"), let match = entries.first(where: { $0.filename == filename + ".3105" }) {
            return match
        }
        return nil
    }

    static func displayName(forBundledFile filename: String) -> String? {
        entry(forBundledFile: filename)?.displayName
    }

    static func entries(in category: Category) -> [Entry] {
        entries.filter { $0.category == category }
    }
}
