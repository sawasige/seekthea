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
    private var classifyTask: Task<Void, Never>?
    var isClassifying: Bool { classifyTask != nil }

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.feedFetcher = FeedFetcher(modelContainer: modelContainer)
        self.aiProcessor = AIProcessor(modelContainer: modelContainer)
        self.interestEngine = InterestEngine(modelContainer: modelContainer)
    }

    /// 全フィードを更新
    func refresh() async {
        isLoading = true
        await feedFetcher.fetchAll { [weak self] message in
            self?.statusMessage = message
        }
        statusMessage = "スコアを計算中..."
        interestEngine.scoreArticles()
        statusMessage = nil
        isLoading = false
    }

    /// 分類をバックグラウンドで実行
    func classifyInBackground(
        onArticleClassified: (@MainActor () -> Void)? = nil,
        onComplete: (@MainActor () -> Void)? = nil
    ) {
        classifyTask?.cancel()
        classifyTask = Task {
            await aiProcessor.classifyBatch(
                onProgress: { [weak self] message in
                    self?.statusMessage = message
                },
                onArticleClassified: {
                    Task { @MainActor in onArticleClassified?() }
                }
            )
            if Task.isCancelled { return }
            statusMessage = nil
            onComplete?()
            classifyTask = nil
        }
    }

    /// 実行中のカテゴリ分類を停止
    func cancelClassification() {
        classifyTask?.cancel()
        classifyTask = nil
        statusMessage = nil
    }

    /// 全記事を公開日時順で取得
    func fetchArticles() -> [Article] {
        let context = modelContainer.mainContext
        var descriptor = FetchDescriptor<Article>(
            sortBy: [SortDescriptor(\Article.publishedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 500
        return (try? context.fetch(descriptor)) ?? []
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
