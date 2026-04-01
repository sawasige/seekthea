import Foundation
import LinkPresentation
import SwiftData

actor ContentEnricher {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// 記事のコンテンツをOGPメタデータで補完
    @MainActor
    func enrich(articleID: PersistentIdentifier) async {
        let context = modelContainer.mainContext
        guard let article = context.model(for: articleID) as? Article,
              !article.isEnriched else { return }

        let provider = LPMetadataProvider()
        do {
            let metadata = try await provider.startFetchingMetadata(for: article.articleURL)

            // OGP画像
            if let imageProvider = metadata.imageProvider {
                if let imageData = try? await loadImageData(from: imageProvider) {
                    // 画像URLは直接取得できないため、ogImageURLはnilのまま
                    // siteFaviconDataに一時的に活用するか、別途URL抽出が必要
                    _ = imageData
                }
            }

            // Favicon
            if let iconProvider = metadata.iconProvider {
                if let iconData = try? await loadImageData(from: iconProvider) {
                    article.siteFaviconData = iconData
                }
            }

            // OGP description はHTMLから直接抽出
            if let ogDesc = await fetchOGDescription(from: article.articleURL) {
                article.ogDescription = ogDesc
            }

            // OGP画像URL もHTMLから抽出
            if article.imageURL == nil, let ogImage = await fetchOGImage(from: article.articleURL) {
                article.ogImageURL = ogImage
            }

            article.isEnriched = true
            try? context.save()
        } catch {
            // エンリッチメント失敗は致命的ではない
            article.isEnriched = true
            try? context.save()
        }
    }

    // MARK: - Private

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

    private func fetchOGDescription(from url: URL) async -> String? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let html = String(data: data, encoding: .utf8) else { return nil }
        return extractMetaContent(from: html, property: "og:description")
    }

    private func fetchOGImage(from url: URL) async -> URL? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let html = String(data: data, encoding: .utf8),
              let urlString = extractMetaContent(from: html, property: "og:image") else { return nil }
        return URL(string: urlString)
    }

    private func extractMetaContent(from html: String, property: String) -> String? {
        // <meta property="og:description" content="...">
        // <meta name="og:description" content="...">
        let patterns = [
            "<meta\\s+property=\"\(property)\"\\s+content=\"([^\"]*)\"",
            "<meta\\s+content=\"([^\"]*)\"\\s+property=\"\(property)\"",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                return String(html[range])
            }
        }
        return nil
    }
}
