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

    private var feedFetcher: FeedFetcher
    private var interestEngine: InterestEngine

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.feedFetcher = FeedFetcher(modelContainer: modelContainer)
        self.interestEngine = InterestEngine(modelContainer: modelContainer)
    }

    /// 全フィードを更新
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        await feedFetcher.fetchAll()
    }

    /// 興味スコアを更新
    func updateRelevanceScores() {
        interestEngine.scoreArticles()
    }
}
