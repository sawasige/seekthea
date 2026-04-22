import Foundation
import CoreData
import SwiftData

/// CloudKit 同期イベントを購読し、import 完了時に dedup を走らせる
/// 同期ステータスとタイムスタンプを Observable として公開する
@Observable
@MainActor
final class CloudSyncObserver {
    static let shared = CloudSyncObserver()

    private(set) var statusMessage: String?
    private(set) var lastImportEndDate: Date?
    private(set) var isImporting = false

    private var modelContainer: ModelContainer?
    private var observer: NSObjectProtocol?

    private init() {}

    /// 通知購読を開始する。複数回呼んでも安全
    func setup(modelContainer: ModelContainer) {
        guard self.modelContainer == nil else { return }
        self.modelContainer = modelContainer
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }
            // MainActor へのホップが必要なため Task でラップ
            Task { @MainActor in
                self.handle(event: event)
            }
        }
    }

    private func handle(event: NSPersistentCloudKitContainer.Event) {
        guard event.type == .import else { return }
        if event.endDate == nil {
            // import 開始
            isImporting = true
            statusMessage = "iCloud から取り込み中..."
        } else {
            // import 完了
            isImporting = false
            lastImportEndDate = event.endDate
            if event.succeeded, let container = modelContainer {
                Task { @MainActor in
                    await DataDeduplicator.run(in: container.mainContext) { [weak self] msg in
                        self?.statusMessage = msg
                    }
                }
            } else {
                statusMessage = nil
            }
        }
    }
}
