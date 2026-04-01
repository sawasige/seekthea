import Foundation
import SwiftData

@Observable
@MainActor
class SourcesViewModel {
    let modelContainer: ModelContainer
    var addingError: String? = nil

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// URLからRSSを自動検出してソースを追加
    func addSource(url: URL) async throws {
        addingError = nil

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
