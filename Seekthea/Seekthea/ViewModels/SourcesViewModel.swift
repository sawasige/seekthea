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

    /// 指定カテゴリの popular プリセットをまとめて追加（オンボーディング用）
    @discardableResult
    func addPopularSources(forCategories categories: [String]) -> Int {
        let context = modelContainer.mainContext
        let existing = (try? context.fetch(FetchDescriptor<Source>())) ?? []
        let existingURLs = Set(existing.map(\.feedURL))

        var added = 0
        for cat in categories {
            guard let presets = PresetCatalog.shared[cat] else { continue }
            for preset in presets where preset.popular && !existingURLs.contains(preset.feedURL) {
                let source = Source(
                    name: preset.name,
                    feedURL: preset.feedURL,
                    siteURL: preset.siteURL,
                    category: preset.category,
                    isPreset: true
                )
                context.insert(source)
                added += 1
            }
        }
        try? context.save()
        return added
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
            category: preset.category,
            isPreset: true
        )
        context.insert(source)
        try? context.save()
    }

    /// URLからRSSを自動検出してソースを追加（RSS URLの直接入力にも対応）
    func addSource(url: URL) async throws {
        addingError = nil

        if let feedTitle = await parseFeedTitle(url: url) {
            let context = modelContainer.mainContext
            let source = Source(
                name: feedTitle,
                feedURL: url,
                siteURL: url,
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

        let feedTitle = await parseFeedTitle(url: feedURL)
        let context = modelContainer.mainContext
        let source = Source(
            name: feedTitle ?? url.host() ?? url.absoluteString,
            feedURL: feedURL,
            siteURL: url,
            category: "その他"
        )
        context.insert(source)
        try context.save()
    }

    /// フィードURLからタイトルを取得（RSSでなければnil）
    private func parseFeedTitle(url: URL) async -> String? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let parser = FeedKit.FeedParser(data: data)
        guard case .success(let feed) = parser.parse() else { return nil }
        switch feed {
        case .rss(let rss): return rss.title
        case .atom(let atom): return atom.title
        case .json(let json): return json.title
        }
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

    /// 発見されたドメインをソースとして追加
    func acceptDiscoveredSource(_ domain: DiscoveredDomain) async {
        guard let feedURL = domain.detectedFeedURL else { return }
        let siteURL = URL(string: "https://\(domain.domain)")!
        var name = domain.domain
        if let title = domain.feedTitle {
            name = title
        } else if let title = await parseFeedTitle(url: feedURL) {
            name = title
        }
        let context = modelContainer.mainContext
        let source = Source(
            name: name,
            feedURL: feedURL,
            siteURL: siteURL
        )
        context.insert(source)
        domain.isRejected = true
        try? context.save()
    }

    /// プリセットに対応するソースを削除
    func removePresetSource(_ preset: PresetSource) {
        let context = modelContainer.mainContext
        let existing = (try? context.fetch(FetchDescriptor<Source>())) ?? []
        if let source = existing.first(where: { $0.feedURL == preset.feedURL }) {
            context.delete(source)
            try? context.save()
        }
    }
}

/// プリセット用のOG画像URLキャッシュ（Caches ディレクトリの JSON ファイル）
enum PresetOGImageCache {
    private static let fileName = "preset-og-images.json"
    private static let queue = DispatchQueue(label: "PresetOGImageCache", attributes: .concurrent)
    private static var memoryCache: [String: String] = loadFromDisk()

    private static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(fileName)
    }

    private static func loadFromDisk() -> [String: String] {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func get(for siteURL: URL) -> URL? {
        queue.sync {
            memoryCache[siteURL.absoluteString].flatMap(URL.init(string:))
        }
    }

    static func set(_ imageURL: URL, for siteURL: URL) {
        queue.async(flags: .barrier) {
            memoryCache[siteURL.absoluteString] = imageURL.absoluteString
            guard let url = fileURL,
                  let data = try? JSONEncoder().encode(memoryCache) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    static func clear() {
        queue.async(flags: .barrier) {
            memoryCache.removeAll()
            if let url = fileURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
