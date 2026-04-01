import Foundation
import SwiftData

struct PresetSource: Decodable {
    let name: String
    let feedURL: URL
    let siteURL: URL
    let sourceType: String
    let category: String
}

struct PresetData: Decodable {
    let news: [PresetSource]
    let social: [PresetSource]
    let tech: [PresetSource]

    var all: [PresetSource] {
        news + social + tech
    }
}

struct PresetLoader {
    static func loadIfNeeded(context: ModelContext) throws {
        guard let url = Bundle.main.url(forResource: "preset_sources", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return
        }

        let presets = try JSONDecoder().decode(PresetData.self, from: data)

        // 既存ソースのfeedURLを取得して重複チェック
        let existingSources = (try? context.fetch(FetchDescriptor<Source>())) ?? []
        let existingFeedURLs = Set(existingSources.map(\.feedURL))

        for preset in presets.all {
            guard !existingFeedURLs.contains(preset.feedURL) else { continue }
            let sourceType = SourceType(rawValue: preset.sourceType) ?? .news
            let source = Source(
                name: preset.name,
                feedURL: preset.feedURL,
                siteURL: preset.siteURL,
                sourceType: sourceType,
                category: preset.category,
                isPreset: true
            )
            context.insert(source)
        }
    }
}
