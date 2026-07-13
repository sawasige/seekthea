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
    private var topicDiscovery: TopicFeedDiscovery?
    private static let runInterval: TimeInterval = 82800 // 23時間

    private init() {}

    /// 未確認の候補があるか
    func hasUncheckedSuggestions(in context: ModelContext) -> Bool {
        uncheckedSuggestionCount(in: context) > 0
    }

    /// 未確認の候補数（ドメイン発見 + トピックフィード発見）
    func uncheckedSuggestionCount(in context: ModelContext) -> Int {
        let checkedAt = Date(timeIntervalSince1970: lastCheckedTimestamp)
        let domainPredicate = #Predicate<DiscoveredDomain> {
            $0.isSuggested && !$0.isRejected && $0.detectedFeedURL != nil && $0.lastSeenAt > checkedAt
        }
        let domainCount = (try? context.fetchCount(FetchDescriptor(predicate: domainPredicate))) ?? 0
        let topicPredicate = #Predicate<DiscoveredTopicFeed> {
            $0.feedURL != nil && !$0.isRejected && !$0.isAdded && $0.suggestedAt > checkedAt
        }
        let topicCount = (try? context.fetchCount(FetchDescriptor(predicate: topicPredicate))) ?? 0
        return domainCount + topicCount
    }

    /// 発見画面を確認済みにする
    func markAsChecked() {
        lastCheckedTimestamp = Date().timeIntervalSince1970
    }

    func setup(modelContainer: ModelContainer) {
        if discovery == nil {
            discovery = GoogleNewsDiscovery(modelContainer: modelContainer)
        }
        if topicDiscovery == nil {
            topicDiscovery = TopicFeedDiscovery(modelContainer: modelContainer)
        }
    }

    /// 前回から指定間隔以上経っていれば自動実行
    func runIfDue(interval: TimeInterval = 82800) {
        let elapsed = Date().timeIntervalSince1970 - lastRunTimestamp
        guard elapsed >= interval else { return }
        runIfNeeded()
    }

    /// 実行中でなければ発見を開始
    func runIfNeeded() {
        guard !isRunning, let discovery else { return }
        let topicDiscovery = topicDiscovery
        isRunning = true
        let presetFeedURLs = Set(PresetCatalog.all.map(\.feedURL))
        Task {
            await discovery.discoverNewSources(presetFeedURLs: presetFeedURLs) { message in
                Task { @MainActor in
                    DiscoveryManager.shared.statusMessage = message
                }
            }
            await topicDiscovery?.discoverTopicFeeds { message in
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
