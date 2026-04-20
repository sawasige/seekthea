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

    /// フィードURLから記事タイトルを取得
    static func articleTitles(from url: URL, limit: Int = 3) async -> [String] {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.cachePolicy = .returnCacheDataElseLoad
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return [] }
        let parser = FeedKit.FeedParser(data: data)
        guard case .success(let feed) = parser.parse() else { return [] }
        let titles: [String]
        switch feed {
        case .rss(let rss):
            titles = (rss.items ?? []).compactMap { $0.title }
        case .atom(let atom):
            titles = (atom.entries ?? []).compactMap { $0.title }
        case .json(let json):
            titles = (json.items ?? []).compactMap { $0.title }
        }
        return titles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(limit)
            .map { $0 }
    }

    /// フィードURLからタイトルを取得（RSSでなければnil）
    static func feedTitle(from url: URL) async -> String? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let parser = FeedKit.FeedParser(data: data)
        guard case .success(let feed) = parser.parse() else { return nil }
        let raw: String?
        switch feed {
        case .rss(let rss): raw = rss.title
        case .atom(let atom): raw = atom.title
        case .json(let json): raw = json.title
        }
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
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
