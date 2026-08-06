#if os(iOS)
import Foundation
import BackgroundTasks
import SwiftData
import UIKit
import os

/// BGProcessingTask でフェッチとAI分類をバックグラウンド実行するマネージャ。
/// アプリを開く前に裏で新着処理を進めておくことで、起動直後の
/// カテゴリフィルタ・おすすめ品質を高める。
///
/// Foundation Models はバックグラウンドでは累積制のレート制限があり、
/// 1回の実行で分類できるのは数件程度。ただしシステムが約30分間隔で
/// タスクを走らせるため、新着を小刻みに処理して追い付く設計。
/// レート制限時は AIProcessor 側が記事をマークせずループを中断するので、
/// 未分類のバックログは次回実行に持ち越される。
@MainActor
final class BackgroundRefreshManager {
    static let shared = BackgroundRefreshManager()
    static let taskIdentifier = "com.himatsubu.Seekthea.background-refresh"

    /// RSS配信元への配慮: 前回のBGフェッチからこの間隔が空くまでフェッチしない
    private static let minFetchInterval: TimeInterval = 25 * 60
    private static let lastFetchKey = "lastBackgroundFetchAt"

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Seekthea",
        category: "BackgroundRefresh"
    )
    private var modelContainer: ModelContainer?
    private var isRegistered = false

    private init() {}

    /// App.init から呼ぶ（register は didFinishLaunching 前に必要）
    func register(modelContainer: ModelContainer) {
        guard !isRegistered else { return }
        isRegistered = true
        self.modelContainer = modelContainer

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            guard let task = task as? BGProcessingTask else { return }
            Task { @MainActor in
                Self.shared.handle(task: task)
            }
        }
    }

    /// バックグラウンド移行時に呼ぶ。同一IDの再submitは上書きされるだけなので毎回呼んでよい
    func schedule() {
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error("BGタスクの予約に失敗: \(String(describing: error), privacy: .public)")
        }
    }

    private func handle(task: BGProcessingTask) {
        // 次回分を先に予約して実行機会を途切れさせない
        schedule()

        guard let container = modelContainer else {
            task.setTaskCompleted(success: false)
            return
        }

        let start = Date()
        logger.notice("BGタスク起動 \(self.environmentDescription(), privacy: .public) 未分類: \(self.unclassifiedCount(container))件")

        let work = Task { @MainActor in
            let lastFetch = UserDefaults.standard.double(forKey: Self.lastFetchKey)
            if Date().timeIntervalSince1970 - lastFetch >= Self.minFetchInterval {
                let fetcher = FeedFetcher(modelContainer: container)
                await fetcher.fetchAll { _ in }
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastFetchKey)
                InterestEngine(modelContainer: container).scoreArticles()
                self.logger.notice("フェッチ完了 未分類: \(self.unclassifiedCount(container))件")
            } else {
                self.logger.notice("前回フェッチから間隔が空いていないためフェッチをスキップ")
            }

            if Task.isCancelled { return }

            let processor = AIProcessor(modelContainer: container)
            var classified = 0
            var errors = 0
            await processor.classifyBatch(
                onProgress: nil,
                onArticleClassified: { classified += 1 },
                onError: { message in
                    errors += 1
                    self.logger.error("分類エラー: \(message, privacy: .public)")
                }
            )
            self.logger.notice("分類終了: 成功\(classified)件 / エラー\(errors)件")
        }

        task.expirationHandler = {
            Task { @MainActor in
                Self.shared.logger.notice("時間切れ（expiration handler）→ キャンセル")
                work.cancel()
            }
        }

        Task { @MainActor in
            await work.value
            let elapsed = Int(Date().timeIntervalSince(start))
            self.logger.notice("BGタスク終了 合計\(elapsed)秒 残り未分類: \(self.unclassifiedCount(container))件")
            task.setTaskCompleted(success: true)
        }
    }

    // MARK: - 状態の取得

    private func unclassifiedCount(_ container: ModelContainer) -> Int {
        let descriptor = FetchDescriptor<Article>(
            predicate: #Predicate { $0.aiCategory == nil }
        )
        return (try? container.mainContext.fetchCount(descriptor)) ?? -1
    }

    private func environmentDescription() -> String {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        let state: String
        switch UIDevice.current.batteryState {
        case .charging: state = "充電中"
        case .full: state = "満充電"
        case .unplugged: state = "バッテリー駆動"
        default: state = "不明"
        }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? "低電力モードON" : "低電力モードOFF"
        return "\(state)(\(Int(level * 100))%) \(lowPower)"
    }
}
#endif
