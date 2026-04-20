import Foundation

/// AI要約結果のメモリキャッシュ
/// アプリ起動中のみ保持、再起動でクリア。リーダー本文と同じ設計
@Observable
@MainActor
final class AISummaryCache {
    static let shared = AISummaryCache()
    private var summaries: [UUID: String] = [:]

    private init() {}

    func get(_ id: UUID) -> String? {
        summaries[id]
    }

    func set(_ summary: String, for id: UUID) {
        summaries[id] = summary
    }

    func remove(_ id: UUID) {
        summaries.removeValue(forKey: id)
    }

    func clear() {
        summaries.removeAll()
    }
}
