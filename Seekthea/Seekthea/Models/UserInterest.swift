import Foundation
import SwiftData

/// ユーザーが明示的に設定した興味トピック
@Model
class UserInterest {
    var topic: String = ""
    var topicEn: String = ""
    var weight: Double = 1.0  // 1.0 = 通常、0 = 無関心
    var addedAt: Date = Date()

    init(topic: String, topicEn: String = "", weight: Double = 1.0) {
        self.topic = topic
        self.topicEn = topicEn
        self.weight = weight
        self.addedAt = Date()
    }
}
