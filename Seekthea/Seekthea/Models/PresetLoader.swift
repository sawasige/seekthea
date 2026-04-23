import Foundation

struct PresetSource: Decodable, Hashable, Identifiable {
    let name: String
    let feedURL: URL
    let siteURL: URL
    let category: String
    let popular: Bool

    var id: URL { feedURL }
}

/// プリセットRSSカタログ（JSONから読み込み）
struct PresetCatalog {
    static let shared: [String: [PresetSource]] = load()

    static func load() -> [String: [PresetSource]] {
        guard let url = Bundle.main.url(forResource: "preset_sources", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [PresetSource]].self, from: data) else {
            return [:]
        }
        return decoded
    }

    /// 全プリセットをフラットに取得
    static var all: [PresetSource] {
        shared.values.flatMap { $0 }
    }

    /// 全プリセットの feedURL セット（Source の preset 判定で使う）
    static var allFeedURLs: Set<URL> {
        Set(all.map(\.feedURL))
    }

    /// カテゴリ順のキー配列（表示順を固定）
    static let categoryOrder = [
        "ニュース", "テクノロジー", "開発", "ビジネス", "エンタメ",
        "アニメ・漫画", "ゲーム", "サイエンス", "スポーツ",
        "クルマ・バイク", "話題", "コラム", "ライフスタイル", "掲示板まとめ"
    ]

    /// オンボーディング用のおすすめプリセット（各カテゴリから popular=true のみ）
    static var popularByCategory: [(String, [PresetSource])] {
        categoryOrder.compactMap { cat in
            guard let presets = shared[cat] else { return nil }
            let popular = presets.filter(\.popular)
            return popular.isEmpty ? nil : (cat, popular)
        }
    }
}
