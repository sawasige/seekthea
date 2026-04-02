import Foundation
import SwiftData

enum ContentCategory: String, CaseIterable, Identifiable {
    case all = "全て"
    case technology = "テクノロジー"
    case business = "ビジネス"
    case politics = "政治"
    case society = "社会"
    case sports = "スポーツ"
    case entertainment = "エンタメ"
    case science = "サイエンス"
    case lifestyle = "ライフ"
    case dev = "開発"
    case product = "プロダクト"
    case trend = "トレンド"

    var id: String { rawValue }
}

@Observable
@MainActor
class FeedViewModel {
    let modelContainer: ModelContainer
    private(set) var isLoading = false
    var selectedSourceType: SourceType? = nil
    var selectedCategory: ContentCategory? = nil

    private var feedFetcher: FeedFetcher
    private var enrichmentQueue: EnrichmentQueue
    private var aiProcessor: AIProcessor
    private var interestEngine: InterestEngine

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.feedFetcher = FeedFetcher(modelContainer: modelContainer)
        let enricher = ContentEnricher(modelContainer: modelContainer)
        self.enrichmentQueue = EnrichmentQueue(enricher: enricher)
        self.aiProcessor = AIProcessor(modelContainer: modelContainer)
        self.interestEngine = InterestEngine(modelContainer: modelContainer)
    }

    /// 全フィードを更新
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        await feedFetcher.fetchAll()
    }

    /// 表示中の記事をエンリッチ
    func enrichVisibleArticles(_ articles: [Article]) async {
        await enrichmentQueue.enqueueVisible(articles)
    }

    /// 新着記事のAI処理（直近24時間のみ）
    func processUnanalyzedArticles(_ articles: [Article]) async {
        let cutoff = Date().addingTimeInterval(-86400)
        let unprocessed = articles.filter {
            !$0.isAIProcessed && $0.fetchedAt > cutoff
        }
        let ids = unprocessed.map(\.persistentModelID)
        await aiProcessor.processBatch(articleIDs: ids)
    }

    /// 興味スコアを更新
    func updateRelevanceScores() {
        interestEngine.scoreArticles()
    }

    /// フィルタ用のPredicate
    var articlePredicate: Predicate<Article> {
        let sourceTypeRaw = selectedSourceType?.rawValue
        let categoryRaw = selectedCategory?.rawValue

        if let sourceTypeRaw, let categoryRaw {
            return #Predicate<Article> { article in
                article.source?.sourceType == sourceTypeRaw &&
                (article.aiCategory == categoryRaw || article.source?.category == categoryRaw)
            }
        } else if let sourceTypeRaw {
            return #Predicate<Article> { article in
                article.source?.sourceType == sourceTypeRaw
            }
        } else if let categoryRaw {
            return #Predicate<Article> { article in
                article.aiCategory == categoryRaw || article.source?.category == categoryRaw
            }
        } else {
            return #Predicate<Article> { _ in true }
        }
    }
}
