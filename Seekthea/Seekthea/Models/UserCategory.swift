import Foundation
import SwiftData

@Model
class UserCategory {
    var id: UUID = UUID()
    var name: String = ""
    var order: Int = 0
    var addedAt: Date = Date()
    /// AI分類のヒントとなる説明文（記事のどんな内容がこのカテゴリに属するか）。
    /// 空文字の場合はAIに渡さない。
    var aiHint: String = ""

    init(name: String, order: Int, aiHint: String = "") {
        self.id = UUID()
        self.name = name
        self.order = order
        self.addedAt = Date()
        self.aiHint = aiHint
    }

    static let defaults = ["政治", "経済", "社会", "国際", "テクノロジー", "科学", "スポーツ", "エンタメ", "ライフ", "開発"]

    /// デフォルトカテゴリのAIヒント。seedIfNeeded と backfillHintsIfNeeded から参照
    static let defaultHints: [String: String] = [
        "政治": "政府・国会の動き、選挙、政策、外交、与野党（個別の事件・事故は「社会」、企業業績は「経済」、スポーツ選手の処遇は「スポーツ」）",
        "経済": "株、為替、企業業績、市場、金融、決算、M&A、物価",
        "社会": "事件、事故、犯罪、災害、社会問題、地域ニュース、店舗運営の話題",
        "国際": "海外ニュース、国際関係、外国情勢（米政権の動き、各国首脳）",
        "テクノロジー": "IT、AI、ガジェット、新技術、ソフトウェア（個別企業の業績は「経済」、店舗運営の話は「社会」、コーディングは「開発」）",
        "科学": "宇宙、物理、生物、研究、学術",
        "スポーツ": "野球、サッカー、選手、試合、オリンピック、チーム成績、選手の去就",
        "エンタメ": "芸能、YouTuber、VTuber、映画、音楽、テレビ、ネット話題",
        "ライフ": "暮らし、料理、ファッション、健康、住まい、グルメ",
        "開発": "プログラミング、エンジニアリング、コード、フレームワーク、開発者向けツール"
    ]

    /// 空なら既定カテゴリを投入
    @MainActor
    static func seedIfNeeded(context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<UserCategory>())) ?? []
        guard existing.isEmpty else { return }
        for (idx, name) in defaults.enumerated() {
            let hint = defaultHints[name] ?? ""
            context.insert(UserCategory(name: name, order: idx, aiHint: hint))
        }
        try? context.save()
    }

    /// 既存ユーザーで aiHint が空の既定カテゴリに、デフォルトのヒントを埋める。
    /// （aiHint フィールド追加前から使っているユーザー向けのマイグレーション）
    @MainActor
    static func backfillHintsIfNeeded(context: ModelContext) {
        let categories = (try? context.fetch(FetchDescriptor<UserCategory>())) ?? []
        var changed = false
        for cat in categories where cat.aiHint.isEmpty {
            if let hint = defaultHints[cat.name] {
                cat.aiHint = hint
                changed = true
            }
        }
        if changed { try? context.save() }
    }
}
