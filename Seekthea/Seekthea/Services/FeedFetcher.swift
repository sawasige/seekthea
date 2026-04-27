import Foundation
import FeedKit
import SwiftData

@MainActor
class FeedFetcher {
    private let modelContainer: ModelContainer
    private var isFetching = false

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// アクティブな全ソースからRSS取得
    func fetchAll(onProgress: ((String?) -> Void)? = nil) async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Source>(predicate: #Predicate { $0.isActive })
        guard let sources = try? context.fetch(descriptor) else { return }

        // articleURL → 既存記事のマップ（孤児記事の再紐付けに使う）
        let existingArticles = (try? context.fetch(FetchDescriptor<Article>())) ?? []
        var articlesByURL: [URL: Article] = [:]
        for article in existingArticles {
            articlesByURL[article.articleURL] = article
        }

        // 30日より古い記事は取り込まない（cleanup と整合）
        let publishedCutoff = Calendar.current.date(
            byAdding: .day,
            value: -ArticleCleanupService.retentionDays,
            to: Date()
        )!

        for (index, source) in sources.enumerated() {
            onProgress?("\(source.name) を取得中... (\(index + 1)/\(sources.count))")
            let feedURL = source.feedURL
            guard let (data, _) = try? await URLSession.shared.data(from: feedURL) else { continue }

            let parser = FeedParser(data: data)
            guard case .success(let feed) = parser.parse() else { continue }

            // 既存ソースの siteURL が feedURL と同じなら（手動でRSS直入力した過去ソース）、
            // フィードの channel link で更新する（マイグレーション）
            if source.siteURL == source.feedURL,
               let channelLink = Self.channelLink(from: feed),
               channelLink != source.feedURL {
                source.siteURL = channelLink
            }

            let items = extractItems(from: feed)
            for item in items {
                if let existing = articlesByURL[item.url] {
                    if existing.sourceFeedURL != source.feedURL {
                        existing.source = source
                        existing.sourceFeedURL = source.feedURL
                        existing.sourceName = source.name
                    }
                    // 過去のFeedFetcherバグ等で publishedAt/imageURL が欠けている既存記事を補完
                    if existing.publishedAt == nil, let pub = item.publishedAt {
                        existing.publishedAt = pub
                    }
                    if existing.imageURL == nil, let img = item.imageURL {
                        existing.imageURL = img
                    }
                    continue
                }
                if let pub = item.publishedAt, pub < publishedCutoff { continue }

                let article = Article(
                    title: item.title,
                    articleURL: item.url,
                    leadText: item.description,
                    imageURL: item.imageURL,
                    publishedAt: item.publishedAt,
                    source: source
                )
                context.insert(article)
                articlesByURL[item.url] = article
                source.articleCount += 1
            }
            source.lastFetchedAt = Date()
            onProgress?("\(source.name) を保存中... (\(index + 1)/\(sources.count))")
            try? context.save()
        }
        onProgress?("フィードを更新中...")

        // RSS で画像が取れなかった新規記事の OG画像をプリフェッチ
        // （カード表示時の .task に頼ると一斉表示時に並列フェッチが集中して
        //  失敗しがちなので、ここで並列度を絞ってまとめて取りに行く）
        await prefetchOGImages(context: context, onProgress: onProgress)

        // 記事が増えた後に毎回クリーンアップ（status は同じonProgressに流す）
        await ArticleCleanupService.shared.run(modelContainer: modelContainer, onProgress: onProgress)
    }

    /// 画像URLが空の記事に対して OG 画像を並列度を絞って先取りする
    private func prefetchOGImages(context: ModelContext, onProgress: ((String?) -> Void)?) async {
        let descriptor = FetchDescriptor<Article>(
            predicate: #Predicate<Article> { $0.imageURL == nil && $0.ogImageURL == nil },
            sortBy: [SortDescriptor(\Article.fetchedAt, order: .reverse)]
        )
        var fetched = (try? context.fetch(descriptor)) ?? []
        // 直近の取り込み分のみ対象（古いものはユーザーが見るときに .task で取得）
        let maxTargets = 20
        if fetched.count > maxTargets { fetched = Array(fetched.prefix(maxTargets)) }
        guard !fetched.isEmpty else { return }

        onProgress?("画像を取得中...")

        // SwiftData @Model は Sendable でないので、TaskGroup には id+url のみ渡す
        let targets: [(id: UUID, url: URL)] = fetched.map { ($0.id, $0.articleURL) }
        let lookup = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
        let maxConcurrent = 4

        await withTaskGroup(of: (UUID, URL?).self) { group in
            var iter = targets.makeIterator()
            for _ in 0..<maxConcurrent {
                guard let item = iter.next() else { break }
                group.addTask {
                    let og = await FeedFetcher.fetchOGImage(from: item.url)
                    return (item.id, og)
                }
            }
            while let (id, og) = await group.next() {
                if let og, let article = lookup[id] {
                    article.ogImageURL = og
                }
                if let item = iter.next() {
                    group.addTask {
                        let og = await FeedFetcher.fetchOGImage(from: item.url)
                        return (item.id, og)
                    }
                }
            }
        }
        try? context.save()
        NotificationCenter.default.post(name: .articleEnrichmentCompleted, object: nil)
    }

    static func fetchOGImage(from url: URL) async -> URL? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }

        let html: String
        if let s = String(data: data, encoding: .utf8) {
            html = s
        } else if let s = String(data: data, encoding: .shiftJIS) {
            html = s
        } else if let s = String(data: data, encoding: .japaneseEUC) {
            html = s
        } else {
            return nil
        }

        let patterns = [
            "property\\s*=\\s*[\"']og:image[\"'][^>]+content\\s*=\\s*[\"']([^\"']+)[\"']",
            "content\\s*=\\s*[\"']([^\"']+)[\"'][^>]+property\\s*=\\s*[\"']og:image[\"']",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                return URL(string: String(html[range]))
            }
        }

        return nil
    }

    // MARK: - Private

    /// パース済みフィードからチャンネルリンク（サイトURL）を取り出す
    private static func channelLink(from feed: Feed) -> URL? {
        let raw: String?
        switch feed {
        case .rss(let rss):
            raw = rss.link
        case .atom(let atom):
            raw = atom.links?.first(where: { ($0.attributes?.rel ?? "alternate") == "alternate" })?.attributes?.href
                ?? atom.links?.first?.attributes?.href
        case .json(let json):
            raw = json.homePageURL
        }
        return raw.flatMap { URL(string: $0) }
    }

    private struct FeedItem {
        let title: String
        let url: URL
        let description: String?
        let imageURL: URL?
        let publishedAt: Date?
    }

    private func extractItems(from feed: Feed) -> [FeedItem] {
        switch feed {
        case .rss(let rssFeed):
            return rssFeed.items?.compactMap { item -> FeedItem? in
                // RSSのtitle/linkに改行や前後スペースが含まれる feed があるので必ずtrim
                // （日産ニュースルームなど）
                guard let rawTitle = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTitle.isEmpty,
                      let rawLink = item.link?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let url = URL(string: rawLink).map(Self.upgradedToHTTPS) else { return nil }
                let imageURL = item.enclosure?.attributes?.url
                    .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { URL(string: $0) }
                    ?? item.media?.mediaThumbnails?.first?.attributes?.url
                        .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .flatMap { URL(string: $0) }
                    ?? Self.firstImageURL(in: item.description)
                    ?? Self.firstImageURL(in: item.content?.contentEncoded)
                return FeedItem(
                    title: rawTitle,
                    url: url,
                    description: item.description?.strippingHTML(),
                    imageURL: imageURL.map(Self.upgradedToHTTPS),
                    // RDF (RSS 1.0) は dc:date を使うため pubDate が nil になるのでフォールバック
                    publishedAt: item.pubDate ?? item.dublinCore?.dcDate
                )
            } ?? []

        case .atom(let atomFeed):
            return atomFeed.entries?.compactMap { entry -> FeedItem? in
                guard let rawTitle = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTitle.isEmpty,
                      let rawLink = entry.links?.first?.attributes?.href?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let url = URL(string: rawLink).map(Self.upgradedToHTTPS) else { return nil }
                return FeedItem(
                    title: rawTitle,
                    url: url,
                    description: entry.summary?.value?.strippingHTML(),
                    imageURL: Self.firstImageURL(in: entry.summary?.value).map(Self.upgradedToHTTPS),
                    publishedAt: entry.published ?? entry.updated
                )
            } ?? []

        case .json(let jsonFeed):
            return jsonFeed.items?.compactMap { item -> FeedItem? in
                guard let rawTitle = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTitle.isEmpty,
                      let rawLink = item.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let url = URL(string: rawLink).map(Self.upgradedToHTTPS) else { return nil }
                let imageURL = item.image
                    .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { URL(string: $0) }
                return FeedItem(
                    title: rawTitle,
                    url: url,
                    description: item.summary ?? item.contentText,
                    imageURL: imageURL.map(Self.upgradedToHTTPS),
                    publishedAt: item.datePublished
                )
            } ?? []
        }
    }

    /// http URL を https に昇格する（iOS の ATS で http がブロックされるため）
    static func upgradedToHTTPS(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.scheme = "https"
        return components.url ?? url
    }

    /// HTML文字列の最初の <img src="..."> を抜き出す
    static func firstImageURL(in html: String?) -> URL? {
        guard let html else { return nil }
        let pattern = "<img[^>]+src\\s*=\\s*[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let src = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: src)
    }
}

extension Notification.Name {
    /// FeedFetcher が記事の OG画像プリフェッチを完了したときに投げる
    static let articleEnrichmentCompleted = Notification.Name("articleEnrichmentCompleted")
}

// MARK: - String Extension

extension String {
    nonisolated func strippingHTML() -> String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
