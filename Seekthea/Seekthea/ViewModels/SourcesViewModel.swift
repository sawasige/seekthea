import Foundation
import SwiftData
import FeedKit

struct PreviewArticle: Identifiable {
    let id = UUID()
    let title: String
    let description: String?
    let imageURL: URL?
    let publishedAt: Date?
    let link: URL
}

@Observable
@MainActor
class SourcesViewModel {
    let modelContainer: ModelContainer
    var addingError: String? = nil

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// プリセットからソースを追加
    func addPresetSource(_ preset: PresetSource) {
        // 重複チェック
        let context = modelContainer.mainContext
        let existing = (try? context.fetch(FetchDescriptor<Source>())) ?? []
        guard !existing.contains(where: { $0.feedURL == preset.feedURL }) else { return }

        let source = Source(
            name: preset.name,
            feedURL: preset.feedURL,
            siteURL: preset.siteURL,
            sourceType: .news,
            category: preset.category,
            isPreset: true
        )
        context.insert(source)
        try? context.save()
    }

    /// URLからRSSを自動検出してソースを追加（RSS URLの直接入力にも対応）
    func addSource(url: URL) async throws {
        addingError = nil

        if await isRSSFeed(url: url) {
            let context = modelContainer.mainContext
            let source = Source(
                name: url.host() ?? url.absoluteString,
                feedURL: url,
                siteURL: url,
                sourceType: .news,
                category: "その他"
            )
            context.insert(source)
            try context.save()
            return
        }

        guard let feedURL = await RSSDetector.detectFeed(from: url) else {
            addingError = "RSSフィードが見つかりませんでした"
            return
        }

        let context = modelContainer.mainContext
        let source = Source(
            name: url.host() ?? url.absoluteString,
            feedURL: feedURL,
            siteURL: url,
            sourceType: .news,
            category: "その他"
        )
        context.insert(source)
        try context.save()
    }

    /// URLがRSSフィードかどうか判定
    private func isRSSFeed(url: URL) async -> Bool {
        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return false }

        if let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() {
            if mime.contains("rss") || mime.contains("atom") || mime.contains("xml") || mime.contains("json") {
                let parser = FeedKit.FeedParser(data: data)
                if case .success = parser.parse() { return true }
            }
        }

        let parser = FeedKit.FeedParser(data: data)
        if case .success = parser.parse() { return true }

        return false
    }

    /// プレビュー用にフィードを取得
    func previewFeed(url: URL) async -> [PreviewArticle] {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return [] }
        let parser = FeedKit.FeedParser(data: data)
        guard case .success(let feed) = parser.parse() else { return [] }
        return Self.extractPreviewArticles(from: feed).prefix(10).map { $0 }
    }

    static func extractPreviewArticles(from feed: Feed) -> [PreviewArticle] {
        switch feed {
        case .rss(let rss):
            return rss.items?.compactMap { item in
                guard let title = item.title,
                      let link = item.link,
                      let url = URL(string: link) else { return nil }
                let imageURL = item.enclosure?.attributes?.url.flatMap { URL(string: $0) }
                    ?? item.media?.mediaThumbnails?.first?.attributes?.url.flatMap { URL(string: $0) }
                return PreviewArticle(
                    title: title,
                    description: item.description?.strippingHTML(),
                    imageURL: imageURL,
                    publishedAt: item.pubDate,
                    link: url
                )
            } ?? []
        case .atom(let atom):
            return atom.entries?.compactMap { entry in
                guard let title = entry.title,
                      let link = entry.links?.first?.attributes?.href,
                      let url = URL(string: link) else { return nil }
                return PreviewArticle(
                    title: title,
                    description: entry.summary?.value?.strippingHTML(),
                    imageURL: nil,
                    publishedAt: entry.published ?? entry.updated,
                    link: url
                )
            } ?? []
        case .json(let json):
            return json.items?.compactMap { item in
                guard let title = item.title,
                      let urlString = item.url,
                      let url = URL(string: urlString) else { return nil }
                let imageURL = item.image.flatMap { URL(string: $0) }
                return PreviewArticle(
                    title: title,
                    description: item.summary ?? item.contentText,
                    imageURL: imageURL,
                    publishedAt: item.datePublished,
                    link: url
                )
            } ?? []
        }
    }

    /// ソースのOG画像を取得してキャッシュ（登録済みソースのみ）
    func fetchAndCacheOGImage(for source: Source) async {
        guard source.ogImageURL == nil else { return }
        if let ogImage = await FeedFetcher.fetchOGImage(from: source.siteURL) {
            source.ogImageURL = ogImage
            try? modelContainer.mainContext.save()
        }
    }

    /// ソースのON/OFF切り替え
    func toggleSource(_ source: Source) {
        source.isActive.toggle()
        try? modelContainer.mainContext.save()
    }

    /// ソースを削除
    func deleteSource(_ source: Source) {
        modelContainer.mainContext.delete(source)
        try? modelContainer.mainContext.save()
    }

    /// プリセットがすでに登録済みか
    func isAdded(_ preset: PresetSource) -> Bool {
        let context = modelContainer.mainContext
        let existing = (try? context.fetch(FetchDescriptor<Source>())) ?? []
        return existing.contains { $0.feedURL == preset.feedURL }
    }
}

/// プリセット用のOG画像キャッシュ（UserDefaults）
enum PresetOGImageCache {
    static func get(for siteURL: URL) -> URL? {
        let key = "preset-og-image-\(siteURL.absoluteString)"
        if let urlString = UserDefaults.standard.string(forKey: key) {
            return URL(string: urlString)
        }
        return nil
    }

    static func set(_ imageURL: URL, for siteURL: URL) {
        let key = "preset-og-image-\(siteURL.absoluteString)"
        UserDefaults.standard.set(imageURL.absoluteString, forKey: key)
    }
}
