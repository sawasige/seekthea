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
        if event.endDate == nil {
            // 開始
            switch event.type {
            case .setup:
                statusMessage = "iCloud と接続中..."
            case .import:
                isImporting = true
                statusMessage = "iCloud から取り込み中..."
            default:
                break
            }
        } else {
            // 完了
            switch event.type {
            case .import:
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
            case .setup:
                // setup 完了は次の import 開始ですぐ上書きされるが、
                // 何も来ない可能性もあるので一旦消す。
                statusMessage = nil
            default:
                break
            }
        }
    }
}
