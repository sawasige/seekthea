import Foundation
import FeedKit
import SwiftData

actor GoogleNewsDiscovery {
    private let modelContainer: ModelContainer

    static let discoveryFeeds: [(name: String, url: URL)] = [
        ("トップ", URL(string: "https://news.google.com/rss?hl=ja&gl=JP&ceid=JP:ja")!),
        ("テクノロジー", URL(string: "https://news.google.com/rss/topics/CAAqKggKIiRDQkFTRlFvSUwyMHZNRGRqTVhZU0JXcGhMVXBRR2dKS1VDQUFQAQ?hl=ja&gl=JP&ceid=JP:ja")!),
        ("ビジネス", URL(string: "https://news.google.com/rss/topics/CAAqKggKIiRDQkFTRlFvSUwyMHZNRGx6TVdZU0JXcGhMVXBRR2dKS1VDQUFQAQ?hl=ja&gl=JP&ceid=JP:ja")!),
        ("サイエンス", URL(string: "https://news.google.com/rss/topics/CAAqKggKIiRDQkFTRlFvSUwyMHZNRGRqTVhZU0JXcGhMVXBRR2dKS1VDQUFQAQ?hl=ja&gl=JP&ceid=JP:ja")!),
        ("エンタメ", URL(string: "https://news.google.com/rss/topics/CAAqKggKIiRDQkFTRlFvSUwyMHZNREpxYW5RU0JXcGhMVXBRR2dKS1VDQUFQAQ?hl=ja&gl=JP&ceid=JP:ja")!),
    ]

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Google Newsから未知のドメインを発見
    func discoverNewSources() async {
        let context = ModelContext(modelContainer)
        let allSources = (try? context.fetch(FetchDescriptor<Source>())) ?? []
        let knownDomains = Set(allSources.compactMap { $0.siteURL.host()?.replacingOccurrences(of: "www.", with: "") })

        for feed in Self.discoveryFeeds {
            guard let (data, _) = try? await URLSession.shared.data(from: feed.url) else { continue }
            let parser = FeedParser(data: data)
            guard case .success(.rss(let rssFeed)) = parser.parse() else { continue }

            for item in rssFeed.items ?? [] {
                guard let link = item.link else { continue }

                // Google NewsのURLはリダイレクトなので、実際のURLを解決する
                let resolvedURL: URL
                if let url = URL(string: link), url.host() == "news.google.com" {
                    // source要素からドメインを取得（<source url="...">）
                    if let sourceURL = item.source?.attributes?.url,
                       let sURL = URL(string: sourceURL),
                       let host = sURL.host() {
                        let domain = host.replacingOccurrences(of: "www.", with: "")
                        if knownDomains.contains(domain) { continue }
                        await recordDomain(domain, context: context)
                        continue
                    }
                    // リダイレクトを追跡
                    if let actual = await resolveRedirect(url) {
                        resolvedURL = actual
                    } else {
                        continue
                    }
                } else if let url = URL(string: link) {
                    resolvedURL = url
                } else {
                    continue
                }

                guard let host = resolvedURL.host() else { continue }
                let domain = host.replacingOccurrences(of: "www.", with: "")

                if knownDomains.contains(domain) { continue }
                if domain.contains("google.") { continue }

                await recordDomain(domain, context: context)
            }
        }

        try? context.save()

        // 閾値を超えたドメインのRSS検出
        await detectFeedsForFrequentDomains(context: context)
    }

    // MARK: - Private

    private func recordDomain(_ domain: String, context: ModelContext) async {
        let domainPredicate = #Predicate<DiscoveredDomain> { $0.domain == domain }
        if let existing = try? context.fetch(FetchDescriptor(predicate: domainPredicate)).first {
            if !existing.isRejected {
                existing.lastSeenAt = Date()
                existing.mentionCount += 1
            }
        } else {
            let discovered = DiscoveredDomain(domain: domain)
            context.insert(discovered)
        }
    }

    private func detectFeedsForFrequentDomains(context: ModelContext) async {
        // 閾値を1に下げて、初回から検出を試みる
        let predicate = #Predicate<DiscoveredDomain> {
            !$0.isRejected && !$0.isSuggested && $0.detectedFeedURL == nil
        }
        guard let candidates = try? context.fetch(FetchDescriptor(predicate: predicate)) else { return }

        for candidate in candidates {
            guard let siteURL = URL(string: "https://\(candidate.domain)") else { continue }
            if let feedURL = await RSSDetector.detectFeed(from: siteURL) {
                candidate.detectedFeedURL = feedURL
                candidate.isSuggested = true
            } else {
                // RSSが見つからなくてもサイトとして提案（RSSなしでも追加可能にする）
                if candidate.mentionCount >= 2 {
                    candidate.isSuggested = true
                }
            }
        }
        try? context.save()
    }

    /// Google Newsのリダイレクトを解決して実際のURLを取得
    private func resolveRedirect(_ url: URL) async -> URL? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5

        // リダイレクトを手動で追跡
        let session = URLSession(configuration: .ephemeral, delegate: RedirectResolver(), delegateQueue: nil)
        guard let (_, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              let location = httpResponse.value(forHTTPHeaderField: "Location"),
              let resolvedURL = URL(string: location) else {
            return nil
        }
        return resolvedURL
    }
}

// リダイレクトを追跡せずLocationヘッダーを取得するためのデリゲート
private final class RedirectResolver: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // リダイレクトを止めて、リダイレクト先URLを返させる
        completionHandler(nil)
    }
}
