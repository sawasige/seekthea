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

    /// デフォルトカテゴリのAIヒント。seedIfNeeded と backfillHintsIfNeeded から参照。
    /// 短い単語（"IT", "AI" 単体）は LLM が幅広い文脈に引っ張られて誤分類を起こすため、
    /// 具体的なフレーズで書く（例: "生成AI", "IT機器・ガジェット"）。
    /// 「AIで仕事が変わる」「銀行のIT化」のような周辺話題は他カテゴリに流すよう disambiguation する。
    static let defaultHints: [String: String] = [
        "政治": "政府・国会の動き、選挙、政策、外交、与野党、首相会見（個別の事件・事故は「社会」、企業業績は「経済」、スポーツ選手の処遇は「スポーツ」）",
        "経済": "株価・日経平均、為替、企業業績・決算、市場動向、金融政策、M&A、物価、業界再編",
        "社会": "事件、事故、犯罪、災害、社会問題、地域ニュース、店舗運営、システム障害、業務インフラの話題",
        "国際": "海外ニュース、国際関係、外国情勢、米政権の動き、各国首脳",
        "テクノロジー": "IT機器・ガジェット紹介、ソフトウェア新製品、生成AI・機械学習の技術解説、新技術紹介（個別企業の業績は「経済」、店舗運営・システム障害は「社会」、コーディング・開発手法は「開発」、AIを使った社会変化は「社会」）",
        "科学": "宇宙、物理、生物、化学、研究、学術論文、新発見",
        "スポーツ": "野球、サッカー、選手、試合、オリンピック、チーム成績、選手の去就、移籍",
        "エンタメ": "芸能、タレント、YouTuber、VTuber、映画、音楽、テレビ番組、ネット話題、SNS",
        "ライフ": "暮らし、料理、ファッション、健康、住まい、グルメ、子育て",
        "開発": "プログラミング、ソフトウェアエンジニアリング、コーディング、フレームワーク、開発者向けツール、設計手法、技術解説記事"
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

    /// defaultHints のバージョン。内容を更新したら bump する。
    /// 既存ユーザーの DB 上の aiHint を新しい default に上書きするトリガーとして使う。
    static let defaultHintsVersion = 2

    /// 名前がデフォルトカテゴリに一致するものについて、aiHint を現バージョンの
    /// default で上書きする。ユーザーが独自に編集した aiHint は失われる可能性があるが、
    /// defaultHints が更新されるたびに一度だけ走らせる想定（@AppStorage で version 管理）。
    @MainActor
    static func syncDefaultHintsToCurrentVersion(context: ModelContext) {
        let categories = (try? context.fetch(FetchDescriptor<UserCategory>())) ?? []
        var changed = false
        for cat in categories {
            if let hint = defaultHints[cat.name], cat.aiHint != hint {
                cat.aiHint = hint
                changed = true
            }
        }
        if changed { try? context.save() }
    }
}
