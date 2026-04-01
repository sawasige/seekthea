import Foundation
import SwiftData

@Observable
@MainActor
class EnrichmentQueue {
    private let enricher: ContentEnricher
    private var processing = false

    init(enricher: ContentEnricher) {
        self.enricher = enricher
    }

    /// 画面に表示中の記事を優先的にエンリッチ
    func enqueueVisible(_ articles: [Article]) async {
        let unenriched = articles.filter { !$0.isEnriched }
        for article in unenriched {
            await enricher.enrich(articleID: article.persistentModelID)
        }
    }

    /// 新着記事をバックグラウンドでエンリッチ
    func enqueueNew(_ articles: [Article]) async {
        guard !processing else { return }
        processing = true
        defer { processing = false }

        let unenriched = articles.filter { !$0.isEnriched }
        for article in unenriched {
            await enricher.enrich(articleID: article.persistentModelID)
            // レート制限: 連続リクエストを避ける
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}
