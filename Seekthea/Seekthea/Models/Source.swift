import Foundation
import SwiftData

@Model
class Source {
    var id: UUID = UUID()
    var name: String = ""
    var feedURL: URL = URL(string: "https://example.com")!
    var siteURL: URL = URL(string: "https://example.com")!
    var category: String = ""
    var isActive: Bool = true
    var isPreset: Bool = false
    var addedAt: Date = Date()
    var lastFetchedAt: Date? = nil
    var articleCount: Int = 0
    var ogImageURL: URL? = nil

    @Relationship(deleteRule: .cascade, inverse: \Article.source)
    var articles: [Article]? = nil

    init(
        name: String,
        feedURL: URL,
        siteURL: URL,
        category: String = "",
        isPreset: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.feedURL = feedURL
        self.siteURL = siteURL
        self.category = category
        self.isActive = true
        self.isPreset = isPreset
        self.addedAt = Date()
    }
}
