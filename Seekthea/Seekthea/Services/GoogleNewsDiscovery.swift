import Foundation
import FeedKit
import SwiftData

actor GoogleNewsDiscovery {
    private let modelContainer: ModelContainer

    static let discoveryFeeds: [(name: String, url: URL)] = [
        ("トップ", URL(string: "https://news.google.com/rss?hl=ja&gl=JP&ceid=JP:ja")!),
        ("テクノロジー", URL(string: "https://news.google.com/rss/topics/CAAqKggKIiRDQkFTRlFvSUwyMHZNRGRqTVhZU0JXcGhMVXBRR2dKS1VDQUFQAQ?hl=ja&gl=JP&ceid=JP:ja")!),
        ("ビジネス", URL(string: "https://news.google.com/rss/topics/CAAqKggKIiRDQkFTRlFvSUwyMHZNRGx6TVdZU0JXcGhMVXBRR2dKS1VDQUFQAQ?hl=ja&gl=JP&ceid=JP:ja")!),
        ("エンタメ", URL(string: "https://news.google.com/rss/topics/CAAqKggKIiRDQkFTRlFvSUwyMHZNREpxYW5RU0JXcGhMVXBRR2dKS1VDQUFQAQ?hl=ja&gl=JP&ceid=JP:ja")!),
        ("スポーツ", URL(string: "https://news.google.com/rss/topics/CAAqKggKIiRDQkFTRlFvSUwyMHZNRFp1ZEdvU0JXcGhMVXBRR2dKS1VDQUFQAQ?hl=ja&gl=JP&ceid=JP:ja")!),
        ("サイエンス", URL(string: "https://news.google.com/rss/topics/CAAqKggKIiRDQkFTRlFvSUwyMHZNRFp0Y1RjU0JXcGhMVXBRR2dKS1VDQUFQAQ?hl=ja&gl=JP&ceid=JP:ja")!),
        ("健康", URL(string: "https://news.google.com/rss/topics/CAAqKggKIiRDQkFTRlFvSUwyMHZNR3QwTlRFU0JXcGhMVXBRR2dKS1VDQUFQAQ?hl=ja&gl=JP&ceid=JP:ja")!),
    ]

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func discoverNewSources() async {
        let context = ModelContext(modelContainer)
        let allSources = (try? context.fetch(FetchDescriptor<Source>())) ?? []
        let knownDomains = Set(allSources.compactMap { extractDomain(from: $0.siteURL) })

        var discoveredDomains: [String: Int] = [:]

        for feed in Self.discoveryFeeds {
            guard let (data, _) = try? await URLSession.shared.data(from: feed.url) else { continue }
            let parser = FeedParser(data: data)
            guard case .success(.rss(let rssFeed)) = parser.parse() else { continue }

            for item in rssFeed.items ?? [] {
                // 方法1: RSSの<source>タグからドメイン取得（最も確実）
                if let sourceURL = item.source?.attributes?.url,
                   let url = URL(string: sourceURL),
                   let domain = extractDomain(from: url) {
                    if !knownDomains.contains(domain) && !domain.contains("google.") {
                        discoveredDomains[domain, default: 0] += 1
                    }
                    continue
                }

                // 方法2: リンクURLからドメイン取得（リダイレクト追跡）
                if let link = item.link, let url = URL(string: link) {
                    if let domain = extractDomain(from: url), !domain.contains("google.") {
                        if !knownDomains.contains(domain) {
                            discoveredDomains[domain, default: 0] += 1
                        }
                        continue
                    }

                    // Google NewsのURLならリダイレクト先を取得
                    if let resolved = await resolveGoogleNewsURL(url),
                       let domain = extractDomain(from: resolved),
                       !knownDomains.contains(domain) {
                        discoveredDomains[domain, default: 0] += 1
                    }
                }
            }
        }

        // 発見したドメインをDBに記録
        for (domain, count) in discoveredDomains {
            let predicate = #Predicate<DiscoveredDomain> { $0.domain == domain }
            if let existing = try? context.fetch(FetchDescriptor(predicate: predicate)).first {
                if !existing.isRejected {
                    existing.lastSeenAt = Date()
                    existing.mentionCount += count
                }
            } else {
                let discovered = DiscoveredDomain(domain: domain)
                discovered.mentionCount = count
                context.insert(discovered)
            }
        }

        try? context.save()

        // RSS検出して提案
        await detectFeedsForCandidates(context: context)
    }

    // MARK: - Private

    private func extractDomain(from url: URL) -> String? {
        guard let host = url.host() else { return nil }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    private func detectFeedsForCandidates(context: ModelContext) async {
        // isSuggested=trueだがRSSが消えたレコードをリセット
        let brokenPredicate = #Predicate<DiscoveredDomain> {
            $0.isSuggested && !$0.isRejected
        }
        if let broken = try? context.fetch(FetchDescriptor(predicate: brokenPredicate)) {
            for d in broken where d.detectedFeedURL == nil {
                d.isSuggested = false
            }
        }

        let predicate = #Predicate<DiscoveredDomain> {
            !$0.isRejected && !$0.isSuggested
        }
        guard let candidates = try? context.fetch(FetchDescriptor(predicate: predicate)) else { return }

        for candidate in candidates {
            guard let siteURL = URL(string: "https://\(candidate.domain)") else { continue }
            if let feedURL = await RSSDetector.detectFeed(from: siteURL) {
                candidate.detectedFeedURL = feedURL
                candidate.feedTitle = await parseFeedTitle(url: feedURL)
                candidate.isSuggested = true
            }
        }
        try? context.save()
    }

    private func parseFeedTitle(url: URL) async -> String? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let parser = FeedParser(data: data)
        guard case .success(let feed) = parser.parse() else { return nil }
        switch feed {
        case .rss(let rss): return rss.title
        case .atom(let atom): return atom.title
        case .json(let json): return json.title
        }
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
