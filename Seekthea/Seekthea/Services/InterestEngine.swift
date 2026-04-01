import Foundation
import SwiftData

/// ユーザーの興味に基づいて記事をスコアリングする
@MainActor
class InterestEngine {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// 全未スコア記事のrelevanceScoreを更新
    func scoreArticles() {
        let context = modelContainer.mainContext

        // 1. 明示的な興味トピックを取得
        let interests = (try? context.fetch(FetchDescriptor<UserInterest>())) ?? []
        let interestTopics = Dictionary(uniqueKeysWithValues: interests.map { ($0.topic.lowercased(), $0.weight) })

        // 2. 読んだ記事・お気に入りからキーワード傾向を学習
        let learnedTopics = learnFromHistory(context: context)

        // 3. 全トピックをマージ（明示 + 学習）
        var allTopics = learnedTopics
        for (topic, weight) in interestTopics {
            allTopics[topic] = (allTopics[topic] ?? 0) + weight * 2  // 明示的な興味は2倍
        }

        // 4. 未スコアの記事をスコアリング
        let articles = (try? context.fetch(FetchDescriptor<Article>())) ?? []
        for article in articles {
            article.relevanceScore = computeScore(article: article, topics: allTopics)
        }

        try? context.save()
    }

    /// 記事単体のスコアを計算
    func computeScore(article: Article, topics: [String: Double]) -> Double {
        guard !topics.isEmpty else { return 0 }

        var score = 0.0
        let titleLower = article.title.lowercased()
        let categoryLower = (article.aiCategory ?? article.source?.category ?? "").lowercased()
        let keywordsLower = article.keywords.map { $0.lowercased() }
        let descLower = (article.summary ?? article.ogDescription ?? article.leadText ?? "").lowercased()

        for (topic, weight) in topics {
            // タイトルに含まれている → 高スコア
            if titleLower.contains(topic) {
                score += weight * 3.0
            }
            // カテゴリが一致 → 高スコア
            if categoryLower.contains(topic) {
                score += weight * 2.5
            }
            // キーワードに含まれている → 中スコア
            if keywordsLower.contains(where: { $0.contains(topic) }) {
                score += weight * 2.0
            }
            // 説明文に含まれている → 低スコア
            if descLower.contains(topic) {
                score += weight * 1.0
            }
        }

        // 新しい記事にボーナス（24時間以内）
        if let pub = article.publishedAt, pub > Date().addingTimeInterval(-86400) {
            score *= 1.2
        }

        // お気に入りソースからのボーナス
        if let source = article.source {
            let favCount = (source.articles ?? []).filter(\.isFavorite).count
            if favCount > 0 {
                score += Double(min(favCount, 5)) * 0.5
            }
        }

        // 0〜1に正規化（sigmoidライク）
        return min(score / (score + 5.0), 1.0)
    }

    // MARK: - 行動から興味を学習

    private func learnFromHistory(context: ModelContext) -> [String: Double] {
        // お気に入り記事のキーワード・カテゴリを集計
        let favPredicate = #Predicate<Article> { $0.isFavorite }
        let favorites = (try? context.fetch(FetchDescriptor(predicate: favPredicate))) ?? []

        // 既読記事（直近100件）
        var readDescriptor = FetchDescriptor<Article>(
            predicate: #Predicate { $0.isRead },
            sortBy: [SortDescriptor(\Article.fetchedAt, order: .reverse)]
        )
        readDescriptor.fetchLimit = 100
        let readArticles = (try? context.fetch(readDescriptor)) ?? []

        var topicCounts: [String: Double] = [:]

        // お気に入りは重み3倍
        for article in favorites {
            for keyword in article.keywords {
                let k = keyword.lowercased()
                topicCounts[k, default: 0] += 3.0
            }
            if let cat = article.aiCategory {
                topicCounts[cat.lowercased(), default: 0] += 2.0
            }
        }

        // 既読は重み1倍
        for article in readArticles {
            for keyword in article.keywords {
                let k = keyword.lowercased()
                topicCounts[k, default: 0] += 1.0
            }
            if let cat = article.aiCategory {
                topicCounts[cat.lowercased(), default: 0] += 0.5
            }
        }

        // 出現1回のノイズを除去、重みを正規化
        let maxCount = topicCounts.values.max() ?? 1.0
        return topicCounts
            .filter { $0.value >= 2.0 }
            .mapValues { $0 / maxCount }
    }
}
