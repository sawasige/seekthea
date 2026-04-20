import Foundation

/// AI要約処理中の記事を追跡するシングルトン
/// 新しい記事のAI処理開始時、進行中の他記事Taskを自動キャンセルする（最新優先）
@Observable
@MainActor
final class AIProgressTracker {
    static let shared = AIProgressTracker()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    private init() {}

    /// 進行中の他記事タスクを全てキャンセルし、新しいタスクを記録
    func start(_ id: UUID, task: Task<Void, Never>) {
        for (existingId, existingTask) in tasks where existingId != id {
            existingTask.cancel()
        }
        tasks[id] = task
    }

    /// タスク完了/キャンセル時に呼ぶ
    func finish(_ id: UUID) {
        tasks.removeValue(forKey: id)
    }

    func isProcessing(_ id: UUID) -> Bool {
        tasks[id] != nil
    }
}
