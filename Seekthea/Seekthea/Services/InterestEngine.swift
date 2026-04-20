import Foundation
import SwiftData
import NaturalLanguage

/// スコアの内訳を表す構造体
struct ScoreBreakdown {
    var totalScore: Double = 0
    var keywordRawScore: Double = 0
    var keywordScore: Double = 0  // 正規化後
    var matchedTopics: [(topic: String, weight: Double, multiplier: Double, matchType: String, contribution: Double)] = []
    var semanticRawScore: Double = 0
    var semanticScore: Double = 0  // 正規化後
    var semanticMatches: [(interestKeyword: String, articleKeyword: String, weight: Double, similarity: Double, contribution: Double)] = []
    var recencyBonus: Double = 1.0
    var impressionPenalty: Double = 1.0
    var impressionCount: Int = 0
    var keywordWeight: Double = 0.4
    var semanticWeight: Double = 0.6
}

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

        // 5. 全記事をスコアリング
        let articles = (try? context.fetch(FetchDescriptor<Article>())) ?? []
        for article in articles {
            let keywordScore = computeKeywordScore(article: article, topics: allTopics)
            let semanticScore = computeSemanticScore(article: article, interestEnKeywords: interestEnKeywords, wordEmbedding: wordEmbedding)

            // 各スコアを重み付き合算（カテゴリスコアはAI分類の信頼性問題で廃止）
            var score = keywordScore * 0.4 + semanticScore * 0.6


            // 新しい記事にボーナス（24時間以内）
            if let pub = article.publishedAt, pub > Date().addingTimeInterval(-86400) {
                score *= 1.2
            }

            // 表示回数ベースの減衰（未読のまま何度も見た記事を下げる）
            if !article.isRead {
                let impressionPenalty = 1.0 / (1.0 + Double(article.impressionCount) * 0.15)
                score *= impressionPenalty
            }

            // 0〜1に正規化
            article.relevanceScore = min(max(score, 0), 1.0)
        }

        try? context.save()
    }

    /// 1記事だけrelevanceScoreを再計算して保存
    func rescore(article: Article) {
        let context = modelContainer.mainContext
        let interests = (try? context.fetch(FetchDescriptor<UserInterest>())) ?? []
        let interestTopics = Dictionary(uniqueKeysWithValues: interests.map { ($0.topic.lowercased(), $0.weight) })
        let learnedTopics = learnFromHistory(context: context)
        var allTopics = learnedTopics
        for (topic, weight) in interestTopics {
            allTopics[topic] = (allTopics[topic] ?? 0) + weight * 2
        }
        let interestEnKeywords = buildEnglishInterestKeywords(context: context)
        let wordEmbedding = NLEmbedding.wordEmbedding(for: .english)

        let keywordScore = computeKeywordScore(article: article, topics: allTopics)
        let semanticScore = computeSemanticScore(article: article, interestEnKeywords: interestEnKeywords, wordEmbedding: wordEmbedding)
        var score = keywordScore * 0.4 + semanticScore * 0.6

        if let pub = article.publishedAt, pub > Date().addingTimeInterval(-86400) {
            score *= 1.2
        }
        if !article.isRead {
            let impressionPenalty = 1.0 / (1.0 + Double(article.impressionCount) * 0.15)
            score *= impressionPenalty
        }
        article.relevanceScore = min(max(score, 0), 1.0)
        try? context.save()
    }

    /// 1記事のスコア内訳を返す（UI説明用、リアルタイム計算）
    func explainScore(for article: Article) -> ScoreBreakdown {
        let context = modelContainer.mainContext
        var breakdown = ScoreBreakdown()

        // トピック収集
        let interests = (try? context.fetch(FetchDescriptor<UserInterest>())) ?? []
        let interestTopics = Dictionary(uniqueKeysWithValues: interests.map { ($0.topic.lowercased(), $0.weight) })
        let learnedTopics = learnFromHistory(context: context)
        var allTopics = learnedTopics
        for (topic, weight) in interestTopics {
            allTopics[topic] = (allTopics[topic] ?? 0) + weight * 2
        }

        // キーワードスコア
        let titleLower = article.title.lowercased()
        let articleKeywords = article.keywords.map { $0.lowercased() }
        var rawKeyword = 0.0
        for (topic, weight) in allTopics {
            if titleLower.contains(topic) {
                let contribution = weight * 3.0
                rawKeyword += contribution
                breakdown.matchedTopics.append((topic, weight, 3.0, "タイトル", contribution))
            } else if articleKeywords.contains(where: { $0.contains(topic) || topic.contains($0) }) {
                let contribution = weight * 2.0
                rawKeyword += contribution
                breakdown.matchedTopics.append((topic, weight, 2.0, "キーワード", contribution))
            }
        }
        breakdown.keywordRawScore = rawKeyword
        breakdown.keywordScore = min(rawKeyword / (rawKeyword + 2.0), 1.0)
        breakdown.matchedTopics.sort { $0.contribution > $1.contribution }

        // セマンティックスコア（記事キーワードごとに最も近い興味を1つだけ採用、重複排除）
        let interestEnKeywords = buildEnglishInterestKeywords(context: context)
        let articleEnKeywords = article.keywordsEn.map { $0.lowercased() }
        var rawSemantic = 0.0
        if let emb = NLEmbedding.wordEmbedding(for: .english), !articleEnKeywords.isEmpty {
            for articleKw in articleEnKeywords {
                var bestSim = 0.0
                var bestInterest: String? = nil
                var bestWeight = 0.0
                for (interest, weight) in interestEnKeywords {
                    let sim: Double
                    if interest == articleKw {
                        sim = 1.0
                    } else {
                        let distance = emb.distance(between: interest, and: articleKw)
                        sim = max(0, 1.0 - distance / 2.0)
                    }
                    if sim > bestSim {
                        bestSim = sim
                        bestInterest = interest
                        bestWeight = weight
                    }
                }
                if bestSim > 0.5, let interest = bestInterest {
                    let contribution = bestWeight * bestSim
                    rawSemantic += contribution
                    breakdown.semanticMatches.append((interest, articleKw, bestWeight, bestSim, contribution))
                }
            }
        }
        breakdown.semanticRawScore = rawSemantic
        breakdown.semanticScore = min(rawSemantic / (rawSemantic + 1.5), 1.0)
        breakdown.semanticMatches.sort { $0.similarity > $1.similarity }

        // 合計
        var total = breakdown.keywordScore * breakdown.keywordWeight
            + breakdown.semanticScore * breakdown.semanticWeight

        // 新着ボーナス
        if let pub = article.publishedAt, pub > Date().addingTimeInterval(-86400) {
            breakdown.recencyBonus = 1.2
            total *= 1.2
        }

        // 表示回数ペナルティ
        if !article.isRead {
            breakdown.impressionCount = article.impressionCount
            breakdown.impressionPenalty = 1.0 / (1.0 + Double(article.impressionCount) * 0.15)
            total *= breakdown.impressionPenalty
        }

        breakdown.totalScore = min(max(total, 0), 1.0)
        return breakdown
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

        // 各記事キーワードに対して最も近い興味キーワードを1つだけ採用（重複排除）
        var score = 0.0
        for articleKw in articleEnKeywords {
            var bestSim = 0.0
            var bestWeight = 0.0
            for (interest, weight) in interestEnKeywords {
                let sim: Double
                if interest == articleKw {
                    sim = 1.0
                } else {
                    let distance = emb.distance(between: interest, and: articleKw)
                    sim = max(0, 1.0 - distance / 2.0)
                }
                if sim > bestSim {
                    bestSim = sim
                    bestWeight = weight
                }
            }
            if bestSim > 0.5 {
                score += bestWeight * bestSim
            }
        }

        return min(score / (score + 1.5), 1.0)
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
