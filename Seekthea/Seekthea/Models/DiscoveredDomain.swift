import Foundation
import SwiftData

@Model
class DiscoveredDomain {
    var domain: String = ""
    var firstSeenAt: Date = Date()
    var lastSeenAt: Date = Date()
    var mentionCount: Int = 0
    var detectedFeedURL: URL? = nil
    var feedTitle: String? = nil
    var isRejected: Bool = false
    var isSuggested: Bool = false
    /// 最後に RSS detect を試した日時。短期間の再試行を防ぐ。
    /// nil = まだ一度も試していない
    var lastDetectAttemptAt: Date? = nil

    init(domain: String) {
        self.domain = domain
        self.firstSeenAt = Date()
        self.lastSeenAt = Date()
        self.mentionCount = 1
    }
}
