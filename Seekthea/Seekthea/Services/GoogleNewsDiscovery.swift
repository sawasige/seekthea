import Foundation
import FeedKit
import SwiftData

actor GoogleNewsDiscovery {
    private let modelContainer: ModelContainer

    // Google ニュースのトピック ID (CAAqK…) は不定期に廃止される。
    // section/topic/<NAME> 形式は 302 で最新のトピック ID にリダイレクトされるので、
    // URLSession の自動リダイレクト追跡で常に最新フィードを取得できる。
    static let discoveryFeeds: [(name: String, url: URL)] = [
        ("トップ", URL(string: "https://news.google.com/rss?hl=ja&gl=JP&ceid=JP:ja")!),
        ("国際", URL(string: "https://news.google.com/rss/headlines/section/topic/WORLD?hl=ja&gl=JP&ceid=JP:ja")!),
        ("国内", URL(string: "https://news.google.com/rss/headlines/section/topic/NATION?hl=ja&gl=JP&ceid=JP:ja")!),
        ("テクノロジー", URL(string: "https://news.google.com/rss/headlines/section/topic/TECHNOLOGY?hl=ja&gl=JP&ceid=JP:ja")!),
        ("ビジネス", URL(string: "https://news.google.com/rss/headlines/section/topic/BUSINESS?hl=ja&gl=JP&ceid=JP:ja")!),
        ("エンタメ", URL(string: "https://news.google.com/rss/headlines/section/topic/ENTERTAINMENT?hl=ja&gl=JP&ceid=JP:ja")!),
        ("スポーツ", URL(string: "https://news.google.com/rss/headlines/section/topic/SPORTS?hl=ja&gl=JP&ceid=JP:ja")!),
        ("サイエンス", URL(string: "https://news.google.com/rss/headlines/section/topic/SCIENCE?hl=ja&gl=JP&ceid=JP:ja")!),
        ("健康", URL(string: "https://news.google.com/rss/headlines/section/topic/HEALTH?hl=ja&gl=JP&ceid=JP:ja")!),
    ]

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func discoverNewSources(presetFeedURLs: Set<URL> = [], onProgress: (@Sendable (String) -> Void)? = nil) async {
        let context = ModelContext(modelContainer)

        var discoveredDomains: [String: Int] = [:]

        for (index, feed) in Self.discoveryFeeds.enumerated() {
            onProgress?("\(feed.name)のトレンドを確認中... (\(index + 1)/\(Self.discoveryFeeds.count))")
            for (domain, count) in await extractDomains(fromFeed: feed.url) {
                discoveredDomains[domain, default: 0] += count
            }
        }

        // 興味キーワードでも検索して発見の入力を広げる。
        // 固定トピックの上澄み（大手メディア＝RSS非公開）ではなく、
        // ユーザーの興味に沿ったロングテールのドメインが出てくる
        for keyword in selectInterestKeywords(context: context) {
            onProgress?("「\(keyword)」の関連ソースを確認中...")
            guard let url = Self.searchFeedURL(for: keyword) else { continue }
            for (domain, count) in await extractDomains(fromFeed: url) {
                discoveredDomains[domain, default: 0] += count
            }
        }

        // 発見したドメインをDBに記録
        for (domain, count) in discoveredDomains {
            let predicate = #Predicate<DiscoveredDomain> { $0.domain == domain }
            if let existing = try? context.fetch(FetchDescriptor(predicate: predicate)).first {
                if !existing.isRejected {
                    if !existing.isSuggested {
                        existing.lastSeenAt = Date()
                    }
                    existing.mentionCount += count
                }
            } else {
                let discovered = DiscoveredDomain(domain: domain)
                discovered.mentionCount = count
                context.insert(discovered)
            }
        }

        try? context.save()
        onProgress?("\(discoveredDomains.count)件のドメインからRSSを検出中...")

        // RSS検出して提案（1件ずつ保存）
        await detectFeedsForCandidates(context: context, presetFeedURLs: presetFeedURLs, onProgress: onProgress)
    }

    /// 興味キーワードの Google ニュース検索フィードURL
    static func searchFeedURL(for keyword: String) -> URL? {
        var components = URLComponents(string: "https://news.google.com/rss/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: keyword),
            URLQueryItem(name: "hl", value: "ja"),
            URLQueryItem(name: "gl", value: "JP"),
            URLQueryItem(name: "ceid", value: "JP:ja"),
        ]
        return components.url
    }

    // MARK: - Private

    /// フィードを取得して掲載元ドメインごとの出現回数を返す
    private func extractDomains(fromFeed feedURL: URL) async -> [String: Int] {
        guard let (data, _) = try? await URLSession.shared.data(from: feedURL) else { return [:] }
        let parser = FeedParser(data: data)
        guard case .success(.rss(let rssFeed)) = parser.parse() else { return [:] }

        var domains: [String: Int] = [:]
        for item in rssFeed.items ?? [] {
            if let sourceURL = item.source?.attributes?.url,
               let url = URL(string: sourceURL),
               let domain = extractDomain(from: url),
               !domain.contains("google.") {
                domains[domain, default: 0] += 1
                continue
            }

            if let link = item.link, let url = URL(string: link) {
                if let domain = extractDomain(from: url), !domain.contains("google.") {
                    domains[domain, default: 0] += 1
                    continue
                }

                if let resolved = await resolveGoogleNewsURL(url),
                   let domain = extractDomain(from: resolved),
                   !domain.contains("google.") {
                    domains[domain, default: 0] += 1
                }
            }
        }
        return domains
    }

    private func extractDomain(from url: URL) -> String? {
        guard let host = url.host() else { return nil }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    private func detectFeedsForCandidates(context: ModelContext, presetFeedURLs: Set<URL>, onProgress: (@Sendable (String) -> Void)? = nil) async {
        // 既知 feedURL（登録済みSource + プリセット）を集める
        let allSources = (try? context.fetch(FetchDescriptor<Source>())) ?? []
        var knownFeedURLs = Set(allSources.map(\.feedURL))
        knownFeedURLs.formUnion(presetFeedURLs)

        // 既存の suggested レコードを一括検証して
        // (1) RSS リンク消失 (2) 登録済みと重複 (3) 空フィード(items=0) のいずれかならリセット
        // 生き残った feedURL は発見内重複排除用に集める
        let suggestedPredicate = #Predicate<DiscoveredDomain> {
            $0.isSuggested && !$0.isRejected
        }
        var suggestedFeedURLs = Set<URL>()
        if let existingSuggested = try? context.fetch(FetchDescriptor(predicate: suggestedPredicate)) {
            for d in existingSuggested {
                guard let feedURL = d.detectedFeedURL else {
                    d.isSuggested = false
                    continue
                }
                if knownFeedURLs.contains(feedURL) {
                    d.isSuggested = false
                    continue
                }
                // 空フィードと確定したらリセットして再 detect 対象に戻す
                // (例: WordPress のコメントフィードが拾われていたケース)
                // ネットワークエラーで metadata=nil の場合は判断保留
                if let metadata = await RSSDetector.feedMetadata(from: feedURL),
                   metadata.itemCount == 0 {
                    d.isSuggested = false
                    d.detectedFeedURL = nil
                    d.feedTitle = nil
                    d.lastDetectAttemptAt = nil
                    continue
                }
                suggestedFeedURLs.insert(feedURL)
            }
        }

        // detect リトライ間隔（前回試行から 7 日経たないと再試行しない）
        let detectRetryCutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        // 1回しか言及されてないノイズは候補から除外（2回以上の言及があれば信頼）
        let mentionThreshold = 2

        let predicate = #Predicate<DiscoveredDomain> {
            !$0.isRejected
                && !$0.isSuggested
                && $0.mentionCount >= mentionThreshold
                && ($0.lastDetectAttemptAt == nil || $0.lastDetectAttemptAt! < detectRetryCutoff)
        }
        guard let candidates = try? context.fetch(FetchDescriptor(predicate: predicate)) else { return }

        var found = 0
        for (index, candidate) in candidates.enumerated() {
            onProgress?("RSS検出中... (\(index + 1)/\(candidates.count))\(found > 0 ? " \(found)件発見" : "")")
            candidate.lastDetectAttemptAt = Date()
            guard let siteURL = URL(string: "https://\(candidate.domain)") else { continue }
            if let feedURL = await RSSDetector.detectFeed(from: siteURL) {
                // 既知 feedURL（登録済み or プリセット）と一致したら候補から外す
                if knownFeedURLs.contains(feedURL) {
                    continue
                }
                // 発見内で同じ feedURL が既に suggested 済みならスキップ
                if suggestedFeedURLs.contains(feedURL) {
                    continue
                }
                // 記事が 0 件のフィード（lmaga.jp, mantan-web.jp 等）は提案しない
                // lastDetectAttemptAt は既に記録済みなので 7日間は再試行されない
                guard let metadata = await RSSDetector.feedMetadata(from: feedURL),
                      metadata.itemCount > 0 else {
                    continue
                }
                candidate.detectedFeedURL = feedURL
                candidate.feedTitle = metadata.title
                candidate.isSuggested = true
                suggestedFeedURLs.insert(feedURL)
                found += 1
            }
            try? context.save()
        }
    }

    // MARK: - 興味キーワード

    /// 1回の実行で検索に使うキーワード数（配信元負荷・実行時間の抑制）
    private static let searchKeywordsPerRun = 3
    /// ローテーション用の候補プール数。毎回同じ検索にならないようここからサンプリングする
    private static let keywordPoolSize = 12
    /// 候補に採用する最低スコア（お気に入り1件 or 既読3件 or 明示的な興味）
    private static let minKeywordScore = 3.0

    /// 固有の興味を表さない汎用語。カテゴリ横断フィルタの補完
    private static let stopWords: Set<String> = [
        "日本", "米国", "アメリカ", "中国", "東京", "世界",
        "発表", "開催", "公開", "発売", "更新", "対応", "調査", "報告",
        "新作", "最新", "話題", "人気", "注目", "速報",
        "ニュース", "動画", "写真", "画像", "まとめ", "レビュー", "記事",
    ]

    /// お気に入り・閲覧履歴・興味トピックから検索キーワードを選ぶ。
    /// 上位プールからのサンプリングで実行ごとに検索対象を変える
    private func selectInterestKeywords(context: ModelContext) -> [String] {
        var scores: [String: Double] = [:]
        var categorySpread: [String: Set<String>] = [:]
        // 表示・検索用に元の表記を保持（小文字化キー → 初出の表記）
        var originalForm: [String: String] = [:]

        func addSignal(keyword: String, weight: Double, categories: [String]) {
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard key.count >= 2, !Self.stopWords.contains(trimmed) else { return }
            scores[key, default: 0] += weight
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

        let ranked = scores.compactMap { key, score -> (keyword: String, score: Double)? in
            guard score >= Self.minKeywordScore else { return nil }
            guard !excluded.contains(key) else { return nil }
            // 数字だけのキーワード（年号等）は除外
            guard key.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) != nil else { return nil }
            // 4カテゴリ以上に横断して出る語は固有の興味ではなく汎用語
            guard (categorySpread[key]?.count ?? 0) < 4 else { return nil }
            return (originalForm[key] ?? key, score)
        }
        .sorted { $0.score > $1.score }

        return ranked.prefix(Self.keywordPoolSize)
            .shuffled()
            .prefix(Self.searchKeywordsPerRun)
            .map(\.keyword)
    }

    /// Google Newsのリダイレクトを追跡して実際のURLを取得
    private func resolveGoogleNewsURL(_ url: URL) async -> URL? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        let delegate = RedirectCatcher()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        // GETで実際にリクエスト（HEADだとリダイレクトしないサイトがある）
        _ = try? await session.data(from: url)
        return delegate.redirectedURL
    }
}

/// リダイレクト先URLをキャッチするデリゲート
private final class RedirectCatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    var redirectedURL: URL?

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        redirectedURL = request.url
        completionHandler(nil) // リダイレクトを追跡せず止める
    }
}
