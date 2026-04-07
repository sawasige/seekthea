import Foundation
import SwiftData
import FeedKit

@Observable
@MainActor
class SourcesViewModel {
    let modelContainer: ModelContainer
    var addingError: String? = nil

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// URLからRSSを自動検出してソースを追加（RSS URLの直接入力にも対応）
    func addSource(url: URL) async throws {
        addingError = nil

        // まずRSSとして直接パースを試みる
        if await isRSSFeed(url: url) {
            let context = modelContainer.mainContext
            let source = Source(
                name: url.host() ?? url.absoluteString,
                feedURL: url,
                siteURL: url,
                sourceType: .news
            )
            context.insert(source)
            try context.save()
            return
        }

        // RSSでなければサイトURLとしてRSS自動検出
        guard let feedURL = await RSSDetector.detectFeed(from: url) else {
            addingError = "RSSフィードが見つかりませんでした"
            return
        }

        let context = modelContainer.mainContext
        let source = Source(
            name: url.host() ?? url.absoluteString,
            feedURL: feedURL,
            siteURL: url,
            sourceType: .news
        )
        context.insert(source)
        try context.save()
    }

    /// URLがRSSフィードかどうか判定
    private func isRSSFeed(url: URL) async -> Bool {
        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return false }

        // Content-Typeで判定
        if let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() {
            if mime.contains("rss") || mime.contains("atom") || mime.contains("xml") || mime.contains("json") {
                // FeedKitでパースを試みる
                let parser = FeedKit.FeedParser(data: data)
                if case .success = parser.parse() { return true }
            }
        }

        // Content-Typeが不正確な場合でもFeedKitでパースを試みる
        let parser = FeedKit.FeedParser(data: data)
        if case .success = parser.parse() { return true }

        return false
    }

    /// ソースのON/OFF切り替え
    func toggleSource(_ source: Source) {
        source.isActive.toggle()
        try? modelContainer.mainContext.save()
    }

    /// ソースを削除
    func deleteSource(_ source: Source) {
        modelContainer.mainContext.delete(source)
        try? modelContainer.mainContext.save()
    }
}
