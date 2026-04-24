import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Seekthea のユーザー設定と記事履歴の JSON バックアップ／復元
@MainActor
enum SettingsBackup {
    static let currentVersion = 1

    // MARK: - 公開API

    /// 現在の状態を JSON Data にシリアライズ
    static func export(context: ModelContext) throws -> Data {
        let sources = ((try? context.fetch(FetchDescriptor<Source>(sortBy: [SortDescriptor(\.addedAt)]))) ?? []).map {
            SourceBackup(
                name: $0.name,
                feedURL: $0.feedURL,
                siteURL: $0.siteURL,
                category: $0.category,
                isActive: $0.isActive
            )
        }
        let categories = ((try? context.fetch(FetchDescriptor<UserCategory>(sortBy: [SortDescriptor(\.order)]))) ?? []).map {
            CategoryBackup(name: $0.name, order: $0.order, aiHint: $0.aiHint)
        }
        let interests = ((try? context.fetch(FetchDescriptor<UserInterest>(sortBy: [SortDescriptor(\.addedAt)]))) ?? []).map {
            InterestBackup(topic: $0.topic, topicEn: $0.topicEn, weight: $0.weight)
        }
        // 記事履歴は isFavorite / isRead / impressionCount>0 のいずれかを持つものだけ
        let allArticles = (try? context.fetch(FetchDescriptor<Article>())) ?? []
        let history: [ArticleHistoryBackup] = allArticles.compactMap { a in
            guard a.isFavorite || a.isRead || a.impressionCount > 0 else { return nil }
            return ArticleHistoryBackup(
                articleURL: a.articleURL,
                isFavorite: a.isFavorite,
                isRead: a.isRead,
                impressionCount: a.impressionCount
            )
        }

        let payload = BackupPayload(
            version: currentVersion,
            exportedAt: Date(),
            sources: sources,
            categories: categories,
            interests: interests,
            articleHistory: history
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    /// JSON Data を読み込んで現在の context にマージ復元。
    /// 重複検出：Source は feedURL、UserCategory は name、UserInterest は topic、Article は articleURL で判定。
    /// 記事履歴は「isFavorite/isRead は OR マージ、impressionCount は max」。
    @discardableResult
    static func restore(from data: Data, context: ModelContext) throws -> RestoreSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(BackupPayload.self, from: data)

        var summary = RestoreSummary()

        // Sources
        let existingSources = (try? context.fetch(FetchDescriptor<Source>())) ?? []
        let existingFeedURLs = Set(existingSources.map(\.feedURL))
        for s in payload.sources where !existingFeedURLs.contains(s.feedURL) {
            let source = Source(
                name: s.name,
                feedURL: s.feedURL,
                siteURL: s.siteURL,
                category: s.category
            )
            source.isActive = s.isActive
            context.insert(source)
            summary.sourcesAdded += 1
        }

        // Categories
        let existingCategories = (try? context.fetch(FetchDescriptor<UserCategory>())) ?? []
        let categoriesByName = Dictionary(uniqueKeysWithValues: existingCategories.map { ($0.name, $0) })
        for c in payload.categories {
            if let existing = categoriesByName[c.name] {
                // 既存のローカルが空なら、バックアップの aiHint で補完
                if existing.aiHint.isEmpty, !c.aiHint.isEmpty {
                    existing.aiHint = c.aiHint
                    summary.categoriesUpdated += 1
                }
            } else {
                context.insert(UserCategory(name: c.name, order: c.order, aiHint: c.aiHint))
                summary.categoriesAdded += 1
            }
        }

        // Interests
        let existingInterests = (try? context.fetch(FetchDescriptor<UserInterest>())) ?? []
        let existingTopics = Set(existingInterests.map(\.topic))
        for i in payload.interests where !existingTopics.contains(i.topic) {
            context.insert(UserInterest(topic: i.topic, topicEn: i.topicEn, weight: i.weight))
            summary.interestsAdded += 1
        }

        // Article history: articleURL でマッチさせて OR/max マージ
        let allArticles = (try? context.fetch(FetchDescriptor<Article>())) ?? []
        let articlesByURL = Dictionary(grouping: allArticles, by: \.articleURL)
        for h in payload.articleHistory {
            guard let articles = articlesByURL[h.articleURL] else { continue }
            for a in articles {
                let newFav = a.isFavorite || h.isFavorite
                let newRead = a.isRead || h.isRead
                let newImpression = max(a.impressionCount, h.impressionCount)
                if newFav != a.isFavorite || newRead != a.isRead || newImpression != a.impressionCount {
                    a.isFavorite = newFav
                    a.isRead = newRead
                    a.impressionCount = newImpression
                    summary.articlesUpdated += 1
                }
            }
        }

        try? context.save()
        return summary
    }

    // MARK: - Data types

    struct BackupPayload: Codable {
        let version: Int
        let exportedAt: Date
        let sources: [SourceBackup]
        let categories: [CategoryBackup]
        let interests: [InterestBackup]
        let articleHistory: [ArticleHistoryBackup]
    }

    struct SourceBackup: Codable {
        let name: String
        let feedURL: URL
        let siteURL: URL
        let category: String
        let isActive: Bool
    }

    struct CategoryBackup: Codable {
        let name: String
        let order: Int
        let aiHint: String
    }

    struct InterestBackup: Codable {
        let topic: String
        let topicEn: String
        let weight: Double
    }

    struct ArticleHistoryBackup: Codable {
        let articleURL: URL
        let isFavorite: Bool
        let isRead: Bool
        let impressionCount: Int
    }

    struct RestoreSummary {
        var sourcesAdded: Int = 0
        var categoriesAdded: Int = 0
        var categoriesUpdated: Int = 0
        var interestsAdded: Int = 0
        var articlesUpdated: Int = 0

        var summaryText: String {
            var parts: [String] = []
            if sourcesAdded > 0 { parts.append("ソース \(sourcesAdded)件追加") }
            if categoriesAdded > 0 { parts.append("カテゴリ \(categoriesAdded)件追加") }
            if categoriesUpdated > 0 { parts.append("カテゴリ説明 \(categoriesUpdated)件更新") }
            if interestsAdded > 0 { parts.append("興味 \(interestsAdded)件追加") }
            if articlesUpdated > 0 { parts.append("記事履歴 \(articlesUpdated)件更新") }
            return parts.isEmpty ? "変更なし" : parts.joined(separator: "、")
        }
    }
}

// MARK: - FileDocument for file picker

/// fileExporter / fileImporter 用の FileDocument ラッパー
struct SeektheaBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
