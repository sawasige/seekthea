import Foundation
import FeedKit

struct RSSDetector {
    /// サイトURLからRSSフィードを自動検出
    static func detectFeed(from siteURL: URL) async -> URL? {
        // 1. HTMLから<link rel="alternate">を探す
        if let feedURL = await detectFromHTML(siteURL) {
            return feedURL
        }

        // 2. よくあるパスを試す
        return await detectFromCommonPaths(siteURL)
    }

    // MARK: - Private

    private static func detectFromHTML(_ url: URL) async -> URL? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let html = String(data: data, encoding: .utf8) else { return nil }

        let patterns = [
            "<link[^>]+type=\"application/rss\\+xml\"[^>]+href=\"([^\"]*)\"",
            "<link[^>]+type=\"application/atom\\+xml\"[^>]+href=\"([^\"]*)\"",
            "<link[^>]+type=\"application/feed\\+json\"[^>]+href=\"([^\"]*)\"",
            "<link[^>]+href=\"([^\"]*)\"[^>]+type=\"application/rss\\+xml\"",
            "<link[^>]+href=\"([^\"]*)\"[^>]+type=\"application/atom\\+xml\"",
            "<link[^>]+href=\"([^\"]*)\"[^>]+type=\"application/feed\\+json\"",
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let href = String(html[range])
                if let feedURL = URL(string: href, relativeTo: url)?.absoluteURL,
                   await isValidFeed(feedURL) {
                    return feedURL
                }
            }
        }
        return nil
    }

    private static func detectFromCommonPaths(_ url: URL) async -> URL? {
        let commonPaths = [
            "/feed", "/rss", "/rss.xml", "/feed.xml", "/feed/rss2",
            "/atom.xml", "/index.xml", "/blog/feed", "/blog/rss",
            "/news/feed", "/news/rss", "/?feed=rss2",
        ]

        for path in commonPaths {
            guard let testURL = URL(string: path, relativeTo: url)?.absoluteURL else { continue }
            if await isValidFeed(testURL) {
                return testURL
            }
        }
        return nil
    }

    /// FeedKitで実際にパースして有効なフィードか確認
    private static func isValidFeed(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else { return false }

        let parser = FeedKit.FeedParser(data: data)
        if case .success = parser.parse() { return true }
        return false
    }
}
