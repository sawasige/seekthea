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
    func fetchAll() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Source>(predicate: #Predicate { $0.isActive })
        guard let sources = try? context.fetch(descriptor) else { return }

        var knownURLs = Set(
            ((try? context.fetch(FetchDescriptor<Article>())) ?? []).map(\.articleURL)
        )

        for source in sources {
            let feedURL = source.feedURL
            guard let (data, _) = try? await URLSession.shared.data(from: feedURL) else { continue }

            let parser = FeedParser(data: data)
            guard case .success(let feed) = parser.parse() else { continue }

            let items = extractItems(from: feed)
            for item in items {
                guard !knownURLs.contains(item.url) else { continue }
                knownURLs.insert(item.url)

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
        }

        try? context.save()
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
