import Foundation
import FeedKit
import SwiftData

actor FeedFetcher {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// アクティブな全ソースからRSS取得
    func fetchAll() async {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Source>(predicate: #Predicate { $0.isActive })
        guard let sources = try? context.fetch(descriptor) else { return }

        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                let sourceID = source.persistentModelID
                group.addTask {
                    await self.fetchFeed(sourceID: sourceID)
                }
            }
        }
    }

    /// 個別フィード取得
    func fetchFeed(sourceID: PersistentIdentifier) async {
        let context = ModelContext(modelContainer)
        guard let source = context.model(for: sourceID) as? Source else { return }

        let feedURL = source.feedURL
        guard let (data, _) = try? await URLSession.shared.data(from: feedURL) else { return }

        let parser = FeedParser(data: data)
        let result = parser.parse()

        switch result {
        case .success(let feed):
            let items = extractItems(from: feed)
            let existingURLs = existingArticleURLs(for: source, context: context)

            for item in items {
                guard !existingURLs.contains(item.url) else { continue }
                let article = Article(
                    title: item.title,
                    articleURL: item.url,
                    leadText: item.description,
                    imageURL: item.imageURL,
                    publishedAt: item.publishedAt,
                    source: source
                )
                context.insert(article)
                source.articleCount += 1
            }
            source.lastFetchedAt = Date()
            try? context.save()

        case .failure:
            break
        }
    }

    // MARK: - Private

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
                guard let title = item.title,
                      let link = item.link,
                      let url = URL(string: link) else { return nil }
                let imageURL = item.enclosure?.attributes?.url.flatMap { URL(string: $0) }
                    ?? item.media?.mediaThumbnails?.first?.attributes?.url.flatMap { URL(string: $0) }
                return FeedItem(
                    title: title,
                    url: url,
                    description: item.description?.strippingHTML(),
                    imageURL: imageURL,
                    publishedAt: item.pubDate
                )
            } ?? []

        case .atom(let atomFeed):
            return atomFeed.entries?.compactMap { entry -> FeedItem? in
                guard let title = entry.title,
                      let link = entry.links?.first?.attributes?.href,
                      let url = URL(string: link) else { return nil }
                return FeedItem(
                    title: title,
                    url: url,
                    description: entry.summary?.value?.strippingHTML(),
                    imageURL: nil,
                    publishedAt: entry.published ?? entry.updated
                )
            } ?? []

        case .json(let jsonFeed):
            return jsonFeed.items?.compactMap { item -> FeedItem? in
                guard let title = item.title,
                      let urlString = item.url,
                      let url = URL(string: urlString) else { return nil }
                let imageURL = item.image.flatMap { URL(string: $0) }
                return FeedItem(
                    title: title,
                    url: url,
                    description: item.summary ?? item.contentText,
                    imageURL: imageURL,
                    publishedAt: item.datePublished
                )
            } ?? []
        }
    }

    private func existingArticleURLs(for source: Source, context: ModelContext) -> Set<URL> {
        let articles = source.articles
        return Set(articles.map(\.articleURL))
    }
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
