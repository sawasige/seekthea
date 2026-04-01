import Foundation
import FeedKit
import SwiftData

actor GoogleNewsDiscovery {
    private let modelContainer: ModelContainer

    static let discoveryFeeds: [(name: String, url: URL)] = [
        ("トップ", URL(string: "https://news.google.com/rss?hl=ja&gl=JP&ceid=JP:ja")!),
        ("テクノロジー", URL(string: "https://news.google.com/rss/topics/CAAqKggKIiRDQkFTRlFvSUwyMHZNRGRqTVhZU0JXcGhMVXBRR2dKS1VDQUFQAQ?hl=ja&gl=JP&ceid=JP:ja")!),
        ("ビジネス", URL(string: "https://news.google.com/rss/topics/CAAqKggKIiRDQkFTRlFvSUwyMHZNRGx6TVdZU0JXcGhMVXBRR2dKS1VDQUFQAQ?hl=ja&gl=JP&ceid=JP:ja")!),
    ]

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Google Newsから未知のドメインを発見
    func discoverNewSources() async {
        let context = ModelContext(modelContainer)

        for feed in Self.discoveryFeeds {
            guard let (data, _) = try? await URLSession.shared.data(from: feed.url) else { continue }
            let parser = FeedParser(data: data)
            guard case .success(.rss(let rssFeed)) = parser.parse() else { continue }

            for item in rssFeed.items ?? [] {
                guard let link = item.link,
                      let url = URL(string: link),
                      let host = url.host() else { continue }

                let domain = host.replacingOccurrences(of: "www.", with: "")

                // 既知ソースチェック（Predicateではhost()が使えないのでメモリ上で判定）
                let allSources = (try? context.fetch(FetchDescriptor<Source>())) ?? []
                let isKnown = allSources.contains { source in
                    source.siteURL.host() == domain || source.feedURL.host() == domain
                }
                if isKnown { continue }

                // DiscoveredDomain を更新または作成
                let domainPredicate = #Predicate<DiscoveredDomain> { $0.domain == domain }
                if let existing = try? context.fetch(FetchDescriptor(predicate: domainPredicate)).first {
                    existing.lastSeenAt = Date()
                    existing.mentionCount += 1
                } else {
                    let discovered = DiscoveredDomain(domain: domain)
                    context.insert(discovered)
                }
            }
        }

        try? context.save()

        // 閾値を超えたドメインのRSS検出
        await detectFeedsForFrequentDomains(context: context)
    }

    private func detectFeedsForFrequentDomains(context: ModelContext) async {
        let predicate = #Predicate<DiscoveredDomain> {
            $0.mentionCount >= 3 && !$0.isRejected && !$0.isSuggested && $0.detectedFeedURL == nil
        }
        guard let candidates = try? context.fetch(FetchDescriptor(predicate: predicate)) else { return }

        for candidate in candidates {
            guard let siteURL = URL(string: "https://\(candidate.domain)") else { continue }
            if let feedURL = await RSSDetector.detectFeed(from: siteURL) {
                candidate.detectedFeedURL = feedURL
                candidate.isSuggested = true
            }
        }
        try? context.save()
    }
}
