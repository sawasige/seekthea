import Foundation
import SwiftData

/// CloudKit 同期で発生する重複レコードを整理する
/// 起動時とフィードリロード時に呼ばれる
@MainActor
enum DataDeduplicator {
    /// 重複を整理する。各モデルの処理間に Task.yield を挟むので、
    /// onProgress で流したステータスが UI に反映される
    static func run(in context: ModelContext, onProgress: ((String?) -> Void)? = nil) async {
        onProgress?("重複を整理中...")
        await Task.yield()
        dedupSources(context)
        await Task.yield()
        dedupArticles(context)
        await Task.yield()
        dedupDiscoveredDomains(context)
        await Task.yield()
        dedupUserCategories(context)
        await Task.yield()
        dedupUserInterests(context)
        try? context.save()
        onProgress?(nil)
    }

    private static func dedupSources(_ context: ModelContext) {
        let sources = (try? context.fetch(FetchDescriptor<Source>())) ?? []
        var seen = Set<URL>()
        for source in sources {
            if seen.contains(source.feedURL) {
                context.delete(source)
            } else {
                seen.insert(source.feedURL)
            }
        }
    }

    private static func dedupArticles(_ context: ModelContext) {
        let articles = (try? context.fetch(FetchDescriptor<Article>())) ?? []
        var seen = Set<URL>()
        for article in articles {
            if seen.contains(article.articleURL) {
                context.delete(article)
            } else {
                seen.insert(article.articleURL)
            }
        }
    }

    private static func dedupDiscoveredDomains(_ context: ModelContext) {
        let discovered = (try? context.fetch(
            FetchDescriptor<DiscoveredDomain>(sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
        )) ?? []
        var seen: [String: DiscoveredDomain] = [:]
        for d in discovered {
            if let kept = seen[d.domain] {
                kept.mentionCount += d.mentionCount
                if d.isRejected { kept.isRejected = true }
                if d.isSuggested && !kept.isSuggested {
                    kept.isSuggested = true
                    kept.detectedFeedURL = d.detectedFeedURL
                    kept.feedTitle = d.feedTitle
                }
                context.delete(d)
            } else {
                seen[d.domain] = d
            }
        }
    }

    /// 多端末で seedIfNeeded が同期前に独立に走ると、デフォルトカテゴリが N×10 個並ぶ
    private static func dedupUserCategories(_ context: ModelContext) {
        let categories = (try? context.fetch(
            FetchDescriptor<UserCategory>(sortBy: [SortDescriptor(\.addedAt)])
        )) ?? []
        var seen = Set<String>()
        for cat in categories {
            let key = cat.name.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if seen.contains(key) {
                context.delete(cat)
            } else {
                seen.insert(key)
            }
        }
    }

    private static func dedupUserInterests(_ context: ModelContext) {
        let interests = (try? context.fetch(
            FetchDescriptor<UserInterest>(sortBy: [SortDescriptor(\.addedAt)])
        )) ?? []
        var seen = Set<String>()
        for interest in interests {
            let key = interest.topic.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if seen.contains(key) {
                context.delete(interest)
            } else {
                seen.insert(key)
            }
        }
    }
}
