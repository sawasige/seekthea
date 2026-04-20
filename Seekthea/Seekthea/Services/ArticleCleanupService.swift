import Foundation
import SwiftData

/// 古い記事を自動削除するサービス
/// - 30日以上前の記事を削除
/// - 件数が上限を超えたら古いものから削除
/// - お気に入りは無期限保持
@MainActor
final class ArticleCleanupService {
    static let shared = ArticleCleanupService()

    static let retentionDays: Int = 30
    static let maxArticleCount: Int = 2000
    private static let runInterval: TimeInterval = 86400 // 24時間

    @MainActor private var lastRunAt: Double {
        get { UserDefaults.standard.double(forKey: "lastArticleCleanupAt") }
        set { UserDefaults.standard.set(newValue, forKey: "lastArticleCleanupAt") }
    }

    private init() {}

    /// 前回実行から24時間経過していればクリーンアップを実行
    func runIfDue(modelContainer: ModelContainer) {
        let now = Date().timeIntervalSince1970
        guard now - lastRunAt >= Self.runInterval else { return }
        lastRunAt = now
        run(modelContainer: modelContainer)
    }

    /// 即時クリーンアップ実行
    func run(modelContainer: ModelContainer) {
        let context = ModelContext(modelContainer)

        // 1. 30日以上前の非お気に入り記事を削除
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: Date())!
        let oldPredicate = #Predicate<Article> { article in
            article.fetchedAt < cutoff && !article.isFavorite
        }
        try? context.delete(model: Article.self, where: oldPredicate)

        // 2. 残った非お気に入り記事が上限を超えていたら古い順から削除
        let remainingPredicate = #Predicate<Article> { !$0.isFavorite }
        var descriptor = FetchDescriptor<Article>(
            predicate: remainingPredicate,
            sortBy: [SortDescriptor(\.fetchedAt, order: .reverse)]
        )
        descriptor.fetchLimit = Self.maxArticleCount + 500
        if let remaining = try? context.fetch(descriptor), remaining.count > Self.maxArticleCount {
            for article in remaining[Self.maxArticleCount...] {
                context.delete(article)
            }
        }

        try? context.save()
    }

    /// 現在の記事数（お気に入り含む）
    func currentCount(in context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<Article>())) ?? 0
    }
}
