import Foundation
import SwiftData

/// キーワード型フィードを提供するプラットフォーム
nonisolated enum TopicFeedPlatform: String, CaseIterable {
    case qiita
    case zenn
    case googleNews
    case hatena

    var displayName: String {
        switch self {
        case .qiita: return "Qiita"
        case .zenn: return "Zenn"
        case .googleNews: return "Google ニュース"
        case .hatena: return "はてなブックマーク"
        }
    }

    /// キーワードを埋め込んだフィードURL。エンコード不能なら nil
    func feedURL(for keyword: String) -> URL? {
        switch self {
        case .qiita:
            // Qiita はタグを小文字スラッグに 302 リダイレクトするので最初から正規形で持つ
            guard let tag = keyword.lowercased().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
            return URL(string: "https://qiita.com/tags/\(tag)/feed")
        case .zenn:
            // Zenn のトピックは小文字スラッグ
            guard let topic = keyword.lowercased().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
            return URL(string: "https://zenn.dev/topics/\(topic)/feed")
        case .googleNews:
            var components = URLComponents(string: "https://news.google.com/rss/search")!
            components.queryItems = [
                URLQueryItem(name: "q", value: keyword),
                URLQueryItem(name: "hl", value: "ja"),
                URLQueryItem(name: "gl", value: "JP"),
                URLQueryItem(name: "ceid", value: "JP:ja"),
            ]
            return components.url
        case .hatena:
            guard let query = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
            var components = URLComponents(string: "https://b.hatena.ne.jp/q/\(query)")
            components?.queryItems = [
                URLQueryItem(name: "mode", value: "rss"),
                URLQueryItem(name: "sort", value: "recent"),
            ]
            return components?.url
        }
    }

    /// ブラウザで開ける対応ページのURL（サムネイル・「元サイト」リンク用）
    func siteURL(for keyword: String) -> URL {
        let fallback = URL(string: "https://\(host)")!
        switch self {
        case .qiita:
            guard let tag = keyword.lowercased().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return fallback }
            return URL(string: "https://qiita.com/tags/\(tag)") ?? fallback
        case .zenn:
            guard let topic = keyword.lowercased().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return fallback }
            return URL(string: "https://zenn.dev/topics/\(topic)") ?? fallback
        case .googleNews:
            var components = URLComponents(string: "https://news.google.com/search")!
            components.queryItems = [
                URLQueryItem(name: "q", value: keyword),
                URLQueryItem(name: "hl", value: "ja"),
                URLQueryItem(name: "gl", value: "JP"),
                URLQueryItem(name: "ceid", value: "JP:ja"),
            ]
            return components.url ?? fallback
        case .hatena:
            guard let query = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return fallback }
            return URL(string: "https://b.hatena.ne.jp/q/\(query)") ?? fallback
        }
    }

    private var host: String {
        switch self {
        case .qiita: return "qiita.com"
        case .zenn: return "zenn.dev"
        case .googleNews: return "news.google.com"
        case .hatena: return "b.hatena.ne.jp"
        }
    }
}

/// 興味キーワードから自動生成されたトピックフィードの提案。
/// feedURL == nil のレコードは「検証に失敗したキーワード」の記録で、
/// lastAttemptAt から一定期間は再試行しないために残す。
@Model
class DiscoveredTopicFeed {
    var keyword: String = ""
    var platformRaw: String = ""
    var feedURL: URL? = nil
    var feedTitle: String? = nil
    var suggestedAt: Date = Date()
    var lastAttemptAt: Date? = nil
    var isRejected: Bool = false
    var isAdded: Bool = false

    init(keyword: String, platform: TopicFeedPlatform?) {
        self.keyword = keyword
        self.platformRaw = platform?.rawValue ?? ""
        self.suggestedAt = Date()
    }

    var platform: TopicFeedPlatform? {
        TopicFeedPlatform(rawValue: platformRaw)
    }

    var siteURL: URL {
        platform?.siteURL(for: keyword) ?? URL(string: "https://news.google.com")!
    }

    /// 一覧に出せる提案か（検証済みで未処理）
    var isPendingSuggestion: Bool {
        feedURL != nil && !isRejected && !isAdded
    }
}
