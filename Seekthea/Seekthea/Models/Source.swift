import Foundation
import SwiftData

enum SourceType: String, Codable, CaseIterable {
    case news = "ニュース"
    case social = "ソーシャル"
    case tech = "テック"
    case discovery = "発見"
}

@Model
class Source {
    var id: UUID = UUID()
    var name: String = ""
    var feedURL: URL = URL(string: "https://example.com")!
    var siteURL: URL = URL(string: "https://example.com")!
    var sourceType: String = SourceType.news.rawValue
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
        sourceType: SourceType,
        category: String = "",
        isPreset: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.feedURL = feedURL
        self.siteURL = siteURL
        self.sourceType = sourceType.rawValue
        self.category = category
        self.isActive = true
        self.isPreset = isPreset
        self.addedAt = Date()
    }

    var sourceTypeEnum: SourceType {
        get { SourceType(rawValue: sourceType) ?? .news }
        set { sourceType = newValue.rawValue }
    }
}
