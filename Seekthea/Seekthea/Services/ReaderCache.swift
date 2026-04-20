import Foundation

/// セッション中のリーダー抽出結果をメモリキャッシュ
/// アプリ再起動でクリア、メモリ圧迫時にOSが自動退避
@MainActor
final class ReaderCache {
    static let shared = ReaderCache()
    private let cache = NSCache<NSString, CachedEntry>()

    private init() {
        cache.countLimit = 50
    }

    func get(_ id: UUID) -> ReadabilityExtractor.Article? {
        cache.object(forKey: id.uuidString as NSString)?.article
    }

    func set(_ article: ReadabilityExtractor.Article, for id: UUID) {
        cache.setObject(CachedEntry(article: article), forKey: id.uuidString as NSString)
    }

    func clear() {
        cache.removeAllObjects()
    }
}

private final class CachedEntry {
    let article: ReadabilityExtractor.Article
    init(article: ReadabilityExtractor.Article) {
        self.article = article
    }
}
