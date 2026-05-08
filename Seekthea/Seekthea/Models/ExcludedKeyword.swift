import Foundation
import SwiftData

/// ユーザーが明示的に除外したキーワード。
/// 該当キーワードを含む記事は relevanceScore を 0 にして実質的に非表示扱いとする。
@Model
class ExcludedKeyword {
    var id: UUID = UUID()
    var keyword: String = ""
    var addedAt: Date = Date()

    init(keyword: String) {
        self.id = UUID()
        self.keyword = keyword.lowercased().trimmingCharacters(in: .whitespaces)
        self.addedAt = Date()
    }
}
