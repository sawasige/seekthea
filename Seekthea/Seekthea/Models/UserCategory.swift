import Foundation
import SwiftData

@Model
class UserCategory {
    var id: UUID = UUID()
    var name: String = ""
    var order: Int = 0
    var addedAt: Date = Date()

    init(name: String, order: Int) {
        self.id = UUID()
        self.name = name
        self.order = order
        self.addedAt = Date()
    }

    static let defaults = ["政治", "経済", "社会", "国際", "テクノロジー", "科学", "スポーツ", "エンタメ", "ライフ", "開発"]

    /// 空なら既定カテゴリを投入
    @MainActor
    static func seedIfNeeded(context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<UserCategory>())) ?? []
        guard existing.isEmpty else { return }
        for (idx, name) in defaults.enumerated() {
            context.insert(UserCategory(name: name, order: idx))
        }
        try? context.save()
    }
}
