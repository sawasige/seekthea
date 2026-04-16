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
    private var discovery: GoogleNewsDiscovery?

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

    /// 実行中でなければ発見を開始
    func runIfNeeded() {
        guard !isRunning else { return }
        isRunning = true
        Task.detached { [weak self] in
            await self?.discovery?.discoverNewSources { message in
                Task { @MainActor in
                    self?.statusMessage = message
                }
            }
            Task { @MainActor in
                self?.isRunning = false
                self?.statusMessage = nil
                NotificationCenter.default.post(name: .discoveryCompleted, object: nil)
            }
        }
    }
}

extension Notification.Name {
    static let discoveryCompleted = Notification.Name("discoveryCompleted")
}
