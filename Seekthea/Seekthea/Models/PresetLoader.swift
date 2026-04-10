import Foundation

struct PresetSource: Decodable, Hashable, Identifiable {
    let name: String
    let feedURL: URL
    let siteURL: URL
    let category: String

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

    /// カテゴリ順のキー配列（表示順を固定）
    static let categoryOrder = [
        "ニュース", "テクノロジー", "ビジネス", "エンタメ",
        "サイエンス", "ゲーム", "スポーツ", "ライフスタイル"
    ]
}
