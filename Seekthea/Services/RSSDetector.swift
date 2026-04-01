import Foundation

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
            "<link[^>]+href=\"([^\"]*)\"[^>]+type=\"application/rss\\+xml\"",
            "<link[^>]+href=\"([^\"]*)\"[^>]+type=\"application/atom\\+xml\"",
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let href = String(html[range])
                if let feedURL = URL(string: href, relativeTo: url)?.absoluteURL {
                    return feedURL
                }
            }
        }
        return nil
    }

    private static func detectFromCommonPaths(_ url: URL) async -> URL? {
        let commonPaths = ["/feed", "/rss", "/rss.xml", "/feed/rss2", "/atom.xml", "/index.xml"]

        for path in commonPaths {
            guard let testURL = URL(string: path, relativeTo: url)?.absoluteURL else { continue }
            if let (_, response) = try? await URLSession.shared.data(from: testURL),
               let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200,
               let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
               contentType.contains("xml") || contentType.contains("rss") || contentType.contains("atom") {
                return testURL
            }
        }
        return nil
    }
}
