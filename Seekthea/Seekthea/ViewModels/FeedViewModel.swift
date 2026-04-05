import Foundation
import SwiftData

@Observable
@MainActor
class FeedViewModel {
    let modelContainer: ModelContainer
    private(set) var isLoading = false
    var statusMessage: String?

    private var feedFetcher: FeedFetcher
    private var aiProcessor: AIProcessor
    private var interestEngine: InterestEngine

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.feedFetcher = FeedFetcher(modelContainer: modelContainer)
        self.aiProcessor = AIProcessor(modelContainer: modelContainer)
        self.interestEngine = InterestEngine(modelContainer: modelContainer)
    }

    /// 全フィードを更新
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        await feedFetcher.fetchAll { [weak self] message in
            self?.statusMessage = message
        }
    }

    /// 未分類記事をカテゴリ分類
    func classifyAll() async {
        await aiProcessor.classifyBatch { [weak self] message in
            self?.statusMessage = message
        }
        statusMessage = nil
    }

    /// アクティブなソースのfeedURLセットを取得
    func activeSourceFeedURLs() -> Set<URL> {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Source>(predicate: #Predicate { $0.isActive })
        let sources = (try? context.fetch(descriptor)) ?? []
        return Set(sources.map(\.feedURL))
    }

    /// 興味スコアを更新
    func updateRelevanceScores() {
        interestEngine.scoreArticles()
    }
}
