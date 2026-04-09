import Foundation
import SwiftData
import NaturalLanguage

/// ユーザーの興味に基づいて記事をスコアリングする
@MainActor
class InterestEngine {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// 全記事のrelevanceScoreを更新
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
            allTopics[topic] = (allTopics[topic] ?? 0) + weight * 2
        }

        // 4. 英語word embeddingを取得
        let wordEmbedding = NLEmbedding.wordEmbedding(for: .english)

        // 5. 興味の英語キーワードを収集
        let interestEnKeywords = buildEnglishInterestKeywords(context: context)

        print("[Interest] topics=\(allTopics.count) wordEmb=\(wordEmbedding != nil) enKeywords=\(interestEnKeywords.count) catRates=\(categoryReadRateCache?.count ?? 0)")

        // 5. 全記事をスコアリング
        let articles = (try? context.fetch(FetchDescriptor<Article>())) ?? []
        for article in articles {
            let keywordScore = computeKeywordScore(article: article, topics: allTopics)
            let semanticScore = computeSemanticScore(article: article, interestEnKeywords: interestEnKeywords, wordEmbedding: wordEmbedding)
            let categoryScore = computeCategoryScore(article: article, context: context)

            // 各スコアを重み付き合算
            var score = keywordScore * 0.3 + semanticScore * 0.4 + categoryScore * 0.3

            // デバッグ
            if score > 0.10 {
                print("[Score] \(article.title.prefix(30))... kw=\(String(format: "%.2f", keywordScore)) sem=\(String(format: "%.2f", semanticScore)) cat=\(String(format: "%.2f", categoryScore)) total=\(String(format: "%.2f", score))")
            }

            // 新しい記事にボーナス（24時間以内）
            if let pub = article.publishedAt, pub > Date().addingTimeInterval(-86400) {
                score *= 1.2
            }

            // 0〜1に正規化
            article.relevanceScore = min(max(score, 0), 1.0)
        }

        try? context.save()
    }

    // MARK: - キーワードベーススコア（日本語文字列マッチ）

    private func computeKeywordScore(article: Article, topics: [String: Double]) -> Double {
        guard !topics.isEmpty else { return 0 }

        var score = 0.0
        let titleLower = article.title.lowercased()
        let articleKeywords = article.keywords.map { $0.lowercased() }

        for (topic, weight) in topics {
            if titleLower.contains(topic) {
                score += weight * 3.0
            } else if articleKeywords.contains(where: { $0.contains(topic) || topic.contains($0) }) {
                score += weight * 2.0
            }
        }

        return min(score / (score + 2.0), 1.0)
    }

    // MARK: - 英語word embeddingベースのセマンティックスコア

    private func buildEnglishInterestKeywords(context: ModelContext) -> [String: Double] {
        var counts: [String: Double] = [:]

        // UserInterestの英語トピック（明示的な興味、重み高め）
        let interests = (try? context.fetch(FetchDescriptor<UserInterest>())) ?? []
        for interest in interests {
            if !interest.topicEn.isEmpty {
                counts[interest.topicEn.lowercased(), default: 0] += interest.weight * 4.0
            }
        }

        // お気に入り記事の英語キーワード
        let favPredicate = #Predicate<Article> { $0.isFavorite }
        let favorites = (try? context.fetch(FetchDescriptor(predicate: favPredicate))) ?? []

        // 既読記事の英語キーワード
        var readDescriptor = FetchDescriptor<Article>(
            predicate: #Predicate { $0.isRead },
            sortBy: [SortDescriptor(\Article.fetchedAt, order: .reverse)]
        )
        readDescriptor.fetchLimit = 100
        let readArticles = (try? context.fetch(readDescriptor)) ?? []

        for article in favorites {
            for kw in article.keywordsEn {
                counts[kw.lowercased(), default: 0] += 3.0
            }
        }
        for article in readArticles {
            for kw in article.keywordsEn {
                counts[kw.lowercased(), default: 0] += 1.0
            }
        }

        let maxCount = counts.values.max() ?? 1.0
        return counts
            .filter { $0.value >= 2.0 }
            .mapValues { $0 / maxCount }
    }

    private func computeSemanticScore(article: Article, interestEnKeywords: [String: Double], wordEmbedding: NLEmbedding?) -> Double {
        guard let emb = wordEmbedding, !interestEnKeywords.isEmpty else { return 0 }
        let articleEnKeywords = article.keywordsEn.map { $0.lowercased() }
        guard !articleEnKeywords.isEmpty else { return 0 }

        var score = 0.0
        for (interest, weight) in interestEnKeywords {
            // 各興味キーワードに対して最も近い記事キーワードの類似度を取得
            var bestSim = 0.0
            for articleKw in articleEnKeywords {
                if interest == articleKw {
                    bestSim = 1.0
                    break
                }
                let distance = emb.distance(between: interest, and: articleKw)
                let sim = max(0, 1.0 - distance / 2.0)
                bestSim = max(bestSim, sim)
            }
            if bestSim > 0.5 {
                score += weight * bestSim
            }
        }

        return min(score / (score + 1.5), 1.0)
    }

    // MARK: - カテゴリ読了率スコア

    private var categoryReadRateCache: [String: Double]?

    private func computeCategoryScore(article: Article, context: ModelContext) -> Double {
        if categoryReadRateCache == nil {
            categoryReadRateCache = buildCategoryReadRates(context: context)
        }
        guard let rates = categoryReadRateCache,
              let cat = article.aiCategory else { return 0 }
        return rates[cat] ?? 0
    }

    private func buildCategoryReadRates(context: ModelContext) -> [String: Double] {
        let articles = (try? context.fetch(FetchDescriptor<Article>())) ?? []
        var totalByCategory: [String: Int] = [:]
        var readByCategory: [String: Int] = [:]

        for article in articles {
            for cat in article.categories {
                totalByCategory[cat, default: 0] += 1
                if article.isRead {
                    readByCategory[cat, default: 0] += 1
                }
            }
        }

        var rates: [String: Double] = [:]
        for (cat, total) in totalByCategory where total >= 3 {
            rates[cat] = Double(readByCategory[cat] ?? 0) / Double(total)
        }
        return rates
    }

    // MARK: - 行動から興味を学習

    func learnFromHistory(context: ModelContext) -> [String: Double] {
        let favPredicate = #Predicate<Article> { $0.isFavorite }
        let favorites = (try? context.fetch(FetchDescriptor(predicate: favPredicate))) ?? []

        var readDescriptor = FetchDescriptor<Article>(
            predicate: #Predicate { $0.isRead },
            sortBy: [SortDescriptor(\Article.fetchedAt, order: .reverse)]
        )
        readDescriptor.fetchLimit = 100
        let readArticles = (try? context.fetch(readDescriptor)) ?? []

        var topicCounts: [String: Double] = [:]

        for article in favorites {
            for keyword in article.keywords {
                topicCounts[keyword.lowercased(), default: 0] += 3.0
            }
            if let cat = article.aiCategory {
                topicCounts[cat.lowercased(), default: 0] += 2.0
            }
        }

        for article in readArticles {
            for keyword in article.keywords {
                topicCounts[keyword.lowercased(), default: 0] += 1.0
            }
            if let cat = article.aiCategory {
                topicCounts[cat.lowercased(), default: 0] += 0.5
            }
        }

        let maxCount = topicCounts.values.max() ?? 1.0
        return topicCounts
            .filter { $0.value >= 2.0 }
            .mapValues { $0 / maxCount }
    }
}
