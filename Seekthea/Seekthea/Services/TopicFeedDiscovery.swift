import Foundation
import SwiftData

/// ユーザーの興味キーワードからプラットフォームのテンプレートRSS
/// （Qiitaタグ・Zennトピック・Google ニュース検索・はてブ検索）を生成して提案する。
/// サイト単位の GoogleNewsDiscovery と違い、発見のプールがユーザーの読書傾向で
/// 継続的に補充されるのが狙い。
actor TopicFeedDiscovery {
    private let modelContainer: ModelContainer

    /// 1回の実行で検証（外部リクエスト）するキーワード数の上限
    private static let maxAttemptsPerRun = 5
    /// 1回の実行で新規に提案する数の上限
    private static let maxSuggestionsPerRun = 3
    /// 候補に採用する最低スコア（お気に入り1件 or 既読3件 or 明示的な興味）
    private static let minScore = 3.0
    /// 提案するフィードの最低記事数
    private static let minItemCount = 3
    /// 検証失敗キーワードの再試行間隔（日）
    private static let retryAfterDays = 7

    /// カテゴリ横断フィルタをすり抜けやすい汎用語
    private static let stopWords: Set<String> = [
        "日本", "米国", "アメリカ", "中国", "東京", "世界",
        "発表", "開催", "公開", "発売", "更新", "対応", "調査", "報告",
        "新作", "最新", "話題", "人気", "注目", "速報",
        "ニュース", "動画", "写真", "画像", "まとめ", "レビュー", "記事",
    ]

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func discoverTopicFeeds(onProgress: (@Sendable (String) -> Void)? = nil) async {
        let context = ModelContext(modelContainer)

        // 登録済みと重複した提案・追加済みなのに残った提案を掃除
        let registeredFeedURLs = Set(((try? context.fetch(FetchDescriptor<Source>())) ?? []).map(\.feedURL))
        cleanupStaleSuggestions(context: context, registeredFeedURLs: registeredFeedURLs)

        let candidates = collectCandidates(context: context)
        guard !candidates.isEmpty else {
            try? context.save()
            return
        }

        var attempts = 0
        var suggested = 0
        for candidate in candidates {
            if attempts >= Self.maxAttemptsPerRun || suggested >= Self.maxSuggestionsPerRun { break }
            attempts += 1
            onProgress?("「\(candidate.keyword)」のフィードを探索中...")

            let record = existingRecord(for: candidate.keyword, context: context)
                ?? {
                    let new = DiscoveredTopicFeed(keyword: candidate.keyword, platform: nil)
                    context.insert(new)
                    return new
                }()
            record.lastAttemptAt = Date()

            if let hit = await validateFeed(for: candidate, excluding: registeredFeedURLs) {
                record.platformRaw = hit.platform.rawValue
                record.feedURL = hit.feedURL
                record.feedTitle = hit.title
                record.suggestedAt = Date()
                suggested += 1
            }
            try? context.save()
        }
    }

    // MARK: - 候補キーワードの収集

    private struct Candidate {
        let keyword: String
        let score: Double
        let isDev: Bool
    }

    /// お気に入り・閲覧履歴・明示的な興味からキーワード候補をスコアリングして返す
    private func collectCandidates(context: ModelContext) -> [Candidate] {
        var scores: [String: Double] = [:]
        var devCounts: [String: Int] = [:]
        var totalCounts: [String: Int] = [:]
        var categorySpread: [String: Set<String>] = [:]
        // 表示用に元の表記を保持（小文字化キー → 初出の表記）
        var originalForm: [String: String] = [:]

        func addSignal(keyword: String, weight: Double, categories: [String]) {
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard key.count >= 2, !Self.stopWords.contains(trimmed) else { return }
            scores[key, default: 0] += weight
            totalCounts[key, default: 0] += 1
            if categories.contains("開発") {
                devCounts[key, default: 0] += 1
            }
            for cat in categories {
                categorySpread[key, default: []].insert(cat)
            }
            if originalForm[key] == nil {
                originalForm[key] = trimmed
            }
        }

        // お気に入り記事（重み大）
        let favPredicate = #Predicate<Article> { $0.isFavorite }
        let favorites = (try? context.fetch(FetchDescriptor(predicate: favPredicate))) ?? []
        for article in favorites {
            for keyword in article.keywords {
                addSignal(keyword: keyword, weight: 3.0, categories: article.categories)
            }
        }

        // 閲覧履歴（重み中、直近100件）
        var readDescriptor = FetchDescriptor<Article>(
            predicate: #Predicate { $0.isRead },
            sortBy: [SortDescriptor(\Article.fetchedAt, order: .reverse)]
        )
        readDescriptor.fetchLimit = 100
        let readArticles = (try? context.fetch(readDescriptor)) ?? []
        for article in readArticles {
            for keyword in article.keywords {
                addSignal(keyword: keyword, weight: 1.0, categories: article.categories)
            }
        }

        // 明示的な興味トピック（最優先）
        let interests = (try? context.fetch(FetchDescriptor<UserInterest>())) ?? []
        for interest in interests {
            addSignal(keyword: interest.topic, weight: 4.0 * interest.weight, categories: [])
        }

        // 除外キーワード
        let excluded = Set(((try? context.fetch(FetchDescriptor<ExcludedKeyword>())) ?? [])
            .map { $0.keyword.lowercased() })

        // 既出キーワード: 提案済み・スキップ済み・追加済み、または再試行間隔内の失敗記録
        let retryCutoff = Calendar.current.date(byAdding: .day, value: -Self.retryAfterDays, to: Date()) ?? .distantPast
        let existing = (try? context.fetch(FetchDescriptor<DiscoveredTopicFeed>())) ?? []
        var coveredKeywords = Set<String>()
        for record in existing {
            if record.feedURL != nil || record.isRejected || record.isAdded {
                coveredKeywords.insert(record.keyword.lowercased())
            } else if let attempt = record.lastAttemptAt, attempt > retryCutoff {
                coveredKeywords.insert(record.keyword.lowercased())
            }
        }

        // 登録済みソース名に含まれるキーワードは既にカバー済みとみなす
        // （例: "Qiita SwiftUI" を手動登録済みなら swiftui は提案しない）
        let sourceNames = ((try? context.fetch(FetchDescriptor<Source>())) ?? [])
            .map { $0.name.lowercased() }

        return scores.compactMap { key, score -> Candidate? in
            guard score >= Self.minScore else { return nil }
            guard !excluded.contains(key), !coveredKeywords.contains(key) else { return nil }
            // 数字だけのキーワード（年号等）は除外
            guard key.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) != nil else { return nil }
            // 4カテゴリ以上に横断して出る語は固有の興味ではなく汎用語
            guard (categorySpread[key]?.count ?? 0) < 4 else { return nil }
            guard !sourceNames.contains(where: { $0.contains(key) }) else { return nil }
            let total = totalCounts[key] ?? 0
            let dev = devCounts[key] ?? 0
            let isDev = total > 0 && Double(dev) / Double(total) >= 0.5
            return Candidate(keyword: originalForm[key] ?? key, score: score, isDev: isDev)
        }
        .sorted { $0.score > $1.score }
    }

    private func existingRecord(for keyword: String, context: ModelContext) -> DiscoveredTopicFeed? {
        let key = keyword.lowercased()
        let records = (try? context.fetch(FetchDescriptor<DiscoveredTopicFeed>())) ?? []
        return records.first { $0.keyword.lowercased() == key }
    }

    /// 登録済みと重複した提案・追加済み処理漏れの提案を非表示にする
    private func cleanupStaleSuggestions(context: ModelContext, registeredFeedURLs: Set<URL>) {
        let pendingPredicate = #Predicate<DiscoveredTopicFeed> {
            $0.feedURL != nil && !$0.isRejected && !$0.isAdded
        }
        guard let pending = try? context.fetch(FetchDescriptor(predicate: pendingPredicate)) else { return }
        for record in pending {
            if let feedURL = record.feedURL, registeredFeedURLs.contains(feedURL) {
                record.isAdded = true
            }
        }
    }

    // MARK: - フィード検証

    private struct ValidatedFeed {
        let platform: TopicFeedPlatform
        let feedURL: URL
        let title: String?
    }

    /// カテゴリに応じたプラットフォーム優先順でフィードの実在を検証する
    private func validateFeed(for candidate: Candidate, excluding registeredFeedURLs: Set<URL>) async -> ValidatedFeed? {
        // 開発系キーワードはタグフィードが濃い Qiita/Zenn を優先、
        // それ以外は任意キーワードで安定して動く Google ニュース検索 → はてブの順
        let platforms: [TopicFeedPlatform] = candidate.isDev
            ? [.qiita, .zenn, .googleNews]
            : [.googleNews, .hatena]

        for platform in platforms {
            guard let feedURL = platform.feedURL(for: candidate.keyword) else { continue }
            if registeredFeedURLs.contains(feedURL) { continue }
            guard let metadata = await RSSDetector.feedMetadata(from: feedURL),
                  metadata.itemCount >= Self.minItemCount else { continue }
            return ValidatedFeed(platform: platform, feedURL: feedURL, title: metadata.title)
        }
        return nil
    }
}
