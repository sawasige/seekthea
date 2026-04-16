import Foundation
import FeedKit

struct RSSDetector {
    /// サイトURLからRSSフィードを自動検出
    static func detectFeed(from siteURL: URL) async -> URL? {
        // 1. HTMLから<link rel="alternate">を探す
        if let feedURL = await detectFromHTML(siteURL) {
            return feedURL
        }

        // 2. よくあるパスを並行で試す
        return await detectFromCommonPaths(siteURL)
    }

    /// フィードURLからタイトルを取得（RSSでなければnil）
    static func feedTitle(from url: URL) async -> String? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let parser = FeedKit.FeedParser(data: data)
        guard case .success(let feed) = parser.parse() else { return nil }
        switch feed {
        case .rss(let rss): return rss.title
        case .atom(let atom): return atom.title
        case .json(let json): return json.title
        }
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

        return await withTaskGroup(of: URL?.self) { group in
            for path in commonPaths {
                guard let testURL = URL(string: path, relativeTo: url)?.absoluteURL else { continue }
                group.addTask {
                    await isValidFeed(testURL) ? testURL : nil
                }
            }
            for await result in group {
                if let url = result {
                    group.cancelAll()
                    return url
                }
            }
            return nil
        }
    }

    /// FeedKitで実際にパースして有効なフィードか確認
    private static func isValidFeed(_ url: URL) async -> Bool {
        await feedTitle(from: url) != nil
    }
}
