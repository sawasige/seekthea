import Foundation

enum CategoryIcon {
    static func symbol(for category: String) -> String {
        switch category {
        case "ニュース": return "newspaper.fill"
        case "テクノロジー": return "cpu.fill"
        case "開発": return "chevron.left.forwardslash.chevron.right"
        case "ビジネス": return "chart.line.uptrend.xyaxis"
        case "エンタメ": return "film.fill"
        case "サイエンス": return "atom"
        case "ゲーム": return "gamecontroller.fill"
        case "スポーツ": return "figure.run"
        case "ライフスタイル": return "heart.fill"
        default: return "tag.fill"
        }
    }
}
