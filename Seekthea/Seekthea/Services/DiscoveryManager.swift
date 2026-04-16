import Foundation
import SwiftUI
import SwiftData

@Observable
@MainActor
class DiscoveryManager {
    static let shared = DiscoveryManager()

    private(set) var isRunning = false
    var statusMessage: String?
    @ObservationIgnored
    @AppStorage("lastDiscoveryCheckedAt") private var lastCheckedTimestamp: Double = 0
    @ObservationIgnored
    @AppStorage("lastDiscoveryRunAt") private var lastRunTimestamp: Double = 0
    private var discovery: GoogleNewsDiscovery?
    private static let runInterval: TimeInterval = 82800 // 23時間

    private init() {}

    /// 未確認の候補があるか
    func hasUncheckedSuggestions(in context: ModelContext) -> Bool {
        let checkedAt = Date(timeIntervalSince1970: lastCheckedTimestamp)
        let predicate = #Predicate<DiscoveredDomain> {
            $0.isSuggested && !$0.isRejected && $0.detectedFeedURL != nil && $0.lastSeenAt > checkedAt
        }
        return ((try? context.fetchCount(FetchDescriptor(predicate: predicate))) ?? 0) > 0
    }

    /// 発見画面を確認済みにする
    func markAsChecked() {
        lastCheckedTimestamp = Date().timeIntervalSince1970
    }

    func setup(modelContainer: ModelContainer) {
        if discovery == nil {
            discovery = GoogleNewsDiscovery(modelContainer: modelContainer)
        }
    }

    /// 前回から24時間以上経っていれば自動実行
    func runIfDue() {
        let elapsed = Date().timeIntervalSince1970 - lastRunTimestamp
        guard elapsed >= Self.runInterval else { return }
        runIfNeeded()
    }

    /// 実行中でなければ発見を開始
    func runIfNeeded() {
        guard !isRunning, let discovery else { return }
        isRunning = true
        Task {
            await discovery.discoverNewSources { message in
                Task { @MainActor in
                    DiscoveryManager.shared.statusMessage = message
                }
            }
            DiscoveryManager.shared.isRunning = false
            DiscoveryManager.shared.statusMessage = nil
            DiscoveryManager.shared.lastRunTimestamp = Date().timeIntervalSince1970
            NotificationCenter.default.post(name: .discoveryCompleted, object: nil)
        }
    }
}

extension Notification.Name {
    static let discoveryCompleted = Notification.Name("discoveryCompleted")
}
