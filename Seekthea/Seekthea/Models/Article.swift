import Foundation
import SwiftData

@Model
class Article {
    var id: UUID = UUID()
    var title: String = ""
    var articleURL: URL = URL(string: "https://example.com")!
    var leadText: String? = nil
    var imageURL: URL? = nil
    var publishedAt: Date? = nil
    var fetchedAt: Date = Date()

    // Content Enrichment（LPMetadataProvider）
    var ogDescription: String? = nil
    var ogImageURL: URL? = nil
    var siteFaviconData: Data? = nil
    var isEnriched: Bool = false

    // 本文抽出（AI処理の入力用、永続化しない）
    @Transient var extractedBody: String? = nil

    // AI処理結果
    var summary: String? = nil
    var aiCategory: String? = nil
    var keywordsRaw: String = ""
    var keywordsEnRaw: String = ""
    var isAIProcessed: Bool = false

    // パーソナライズ
    var relevanceScore: Double = 0  // 興味スコア（0〜1）
    var impressionCount: Int = 0    // フィードで表示された回数（未読時の興味なしシグナル）

    // ソース紐付け（URLベース、リレーションなし）
    var sourceFeedURL: URL = URL(string: "https://example.com")!
    var sourceName: String = ""

    // ユーザー操作
    var isRead: Bool = false
    var isFavorite: Bool = false

    var source: Source? = nil

    init(
        title: String,
        articleURL: URL,
        leadText: String? = nil,
        imageURL: URL? = nil,
        publishedAt: Date? = nil,
        source: Source? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.articleURL = articleURL
        self.leadText = leadText
        self.imageURL = imageURL
        self.publishedAt = publishedAt
        self.fetchedAt = Date()
        self.source = source
        self.sourceFeedURL = source?.feedURL ?? URL(string: "https://example.com")!
        self.sourceName = source?.name ?? ""
    }

    var keywords: [String] {
        get { keywordsRaw.isEmpty ? [] : keywordsRaw.components(separatedBy: ",") }
        set { keywordsRaw = newValue.joined(separator: ",") }
    }

    var keywordsEn: [String] {
        get { keywordsEnRaw.isEmpty ? [] : keywordsEnRaw.components(separatedBy: ",") }
        set { keywordsEnRaw = newValue.joined(separator: ",") }
    }

    /// カテゴリ配列（カンマ区切りで複数対応）
    var categories: [String] {
        guard let cat = aiCategory, !cat.isEmpty else { return [] }
        return cat.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var displayImageURL: URL? {
        imageURL ?? ogImageURL
    }

    var displayDescription: String? {
        summary ?? ogDescription ?? leadText
    }

    /// カード用（AI要約を含まない軽量な説明文）
    var cardDescription: String? {
        ogDescription ?? leadText
    }

    var textForAI: String {
        let body = extractedBody ?? ogDescription ?? leadText ?? ""
        let truncated = String(body.prefix(2000))
        return "タイトル: \(title)\n内容: \(truncated)"
    }
}
