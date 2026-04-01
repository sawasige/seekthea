import Foundation
import LinkPresentation
import SwiftData
import SwiftSoup

actor ContentEnricher {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// 記事のコンテンツをOGPメタデータ＋本文抽出で補完
    @MainActor
    func enrich(articleID: PersistentIdentifier) async {
        let context = modelContainer.mainContext
        guard let article = context.model(for: articleID) as? Article,
              !article.isEnriched else { return }

        let url = article.articleURL

        // HTML取得（1回だけ）
        let html = await fetchHTML(from: url)

        // LPMetadataProviderでfavicon取得
        await enrichMetadata(article: article)

        // HTMLからOGP + 本文を抽出
        if let html {
            enrichFromHTML(article: article, html: html)
        }

        article.isEnriched = true
        try? context.save()
    }

    // MARK: - Private

    private func fetchHTML(from url: URL) async -> String? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .japaneseEUC)
            ?? String(data: data, encoding: .shiftJIS)
    }

    @MainActor
    private func enrichMetadata(article: Article) async {
        let provider = LPMetadataProvider()
        guard let metadata = try? await provider.startFetchingMetadata(for: article.articleURL) else { return }

        if let iconProvider = metadata.iconProvider {
            if let iconData = try? await loadImageData(from: iconProvider) {
                article.siteFaviconData = iconData
            }
        }
    }

    @MainActor
    private func enrichFromHTML(article: Article, html: String) {
        guard let doc = try? SwiftSoup.parse(html) else { return }

        // OGP description
        if article.ogDescription == nil {
            article.ogDescription = Self.metaContent(doc: doc, property: "og:description")
        }

        // OGP画像
        if article.imageURL == nil && article.ogImageURL == nil {
            if let imageStr = Self.metaContent(doc: doc, property: "og:image") {
                article.ogImageURL = URL(string: imageStr)
            }
        }

        // 本文抽出（@Transient — 永続化されない、AI入力用）
        article.extractedBody = ArticleExtractor.extractBody(from: html)
    }

    private static func metaContent(doc: Document, property: String) -> String? {
        let selectors = [
            "meta[property=\(property)]",
            "meta[name=\(property)]",
        ]
        for selector in selectors {
            if let element = try? doc.select(selector).first(),
               let content = try? element.attr("content"),
               !content.isEmpty {
                return content
            }
        }
        return nil
    }

    @MainActor
    private func loadImageData(from provider: NSItemProvider) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }
}
