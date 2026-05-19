import Foundation
import SwiftData

/// 古い記事と発見ドメインを自動削除するサービス
/// - 30日以上前の記事を削除
/// - 件数が上限を超えたら古いものから削除
/// - お気に入りは無期限保持
/// - 提案も拒否もされていない発見ドメインで 30日 Google News に出てこないものを削除
@MainActor
final class ArticleCleanupService {
    static let shared = ArticleCleanupService()

    static let retentionDays: Int = 30
    static let maxArticleCount: Int = 2000
    /// 発見ドメインの dormant 削除しきい値（日数）
    static let discoveredDomainDormantDays: Int = 30

    private init() {}

    /// クリーンアップ実行
    /// 呼び出し側の onProgress にステータスを流す（直列フロー中は同じchannelで表示を一本化）
    func run(modelContainer: ModelContainer, onProgress: ((String?) -> Void)? = nil) async {
        let context = ModelContext(modelContainer)

        // 削除予定件数を先にカウント（0件なら何もしない）
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: Date())!
        let oldPredicate = #Predicate<Article> { article in
            article.fetchedAt < cutoff && !article.isFavorite
        }
        let oldCount = (try? context.fetchCount(FetchDescriptor<Article>(predicate: oldPredicate))) ?? 0

        let remainingPredicate = #Predicate<Article> { !$0.isFavorite }
        let remainingTotal = (try? context.fetchCount(FetchDescriptor<Article>(predicate: remainingPredicate))) ?? 0
        let excessCount = max(0, remainingTotal - oldCount - Self.maxArticleCount)

        let total = oldCount + excessCount
        var didChange = false

        if total > 0 {
            onProgress?("古い記事を\(total)件削除中...")
            await Task.yield()

            if oldCount > 0 {
                try? context.delete(model: Article.self, where: oldPredicate)
            }
            if excessCount > 0 {
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
            }
            didChange = true
        }

        // 発見ドメインの dormant 削除
        // 拒否/提案中のものはユーザー判断を保持するため残す
        let domainCutoff = Calendar.current.date(byAdding: .day, value: -Self.discoveredDomainDormantDays, to: Date()) ?? .distantPast
        let dormantPredicate = #Predicate<DiscoveredDomain> { d in
            !d.isRejected && !d.isSuggested && d.lastSeenAt < domainCutoff
        }
        if let dormantCount = try? context.fetchCount(FetchDescriptor<DiscoveredDomain>(predicate: dormantPredicate)),
           dormantCount > 0 {
            try? context.delete(model: DiscoveredDomain.self, where: dormantPredicate)
            didChange = true
        }

        if didChange {
            try? context.save()
        }
    }

    /// 現在の記事数（お気に入り含む）
    func currentCount(in context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<Article>())) ?? 0
    }
}
