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

    init(domain: String) {
        self.domain = domain
        self.firstSeenAt = Date()
        self.lastSeenAt = Date()
        self.mentionCount = 1
    }
}
