import Foundation
import SwiftData

struct RemotePresetResponse: Decodable {
    let version: Int
    let updatedAt: String
    let sources: [RemotePresetSource]

    enum CodingKeys: String, CodingKey {
        case version
        case updatedAt = "updated_at"
        case sources
    }
}

struct RemotePresetSource: Decodable {
    let name: String
    let feedURL: URL
    let siteURL: URL
    let category: String
}

@MainActor
class RemotePresetService {
    private let modelContainer: ModelContainer
    private static let lastCheckKey = "remotePresetLastCheck"
    private static let lastVersionKey = "remotePresetLastVersion"
    // TODO: 実際のGitHub PagesのURLに差し替え
    private static let presetURL = URL(string: "https://yourname.github.io/seekthea-presets/sources.json")!

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// 新しいプリセットがあるかチェック（24時間に1回）
    func checkForUpdates() async -> [RemotePresetSource] {
        let lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        let hoursSinceLastCheck = Date().timeIntervalSince(lastCheck) / 3600
        guard hoursSinceLastCheck >= 24 else { return [] }

        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)

        guard let (data, _) = try? await URLSession.shared.data(from: Self.presetURL),
              let response = try? JSONDecoder().decode(RemotePresetResponse.self, from: data) else {
            return []
        }

        let lastVersion = UserDefaults.standard.integer(forKey: Self.lastVersionKey)
        guard response.version > lastVersion else { return [] }

        UserDefaults.standard.set(response.version, forKey: Self.lastVersionKey)

        // 既存ソースと比較して新しいものだけ返す
        let context = modelContainer.mainContext
        let existingSources = (try? context.fetch(FetchDescriptor<Source>())) ?? []
        let existingFeedURLs = Set(existingSources.map(\.feedURL))

        return response.sources.filter { !existingFeedURLs.contains($0.feedURL) }
    }

    /// 提案されたソースを追加
    func addSource(_ preset: RemotePresetSource) {
        let context = modelContainer.mainContext
        let source = Source(
            name: preset.name,
            feedURL: preset.feedURL,
            siteURL: preset.siteURL,
            sourceType: .news,
            category: preset.category,
            isPreset: true
        )
        context.insert(source)
        try? context.save()
    }
}
