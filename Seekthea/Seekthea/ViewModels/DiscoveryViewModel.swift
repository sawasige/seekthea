import Foundation
import SwiftData

@Observable
@MainActor
class DiscoveryViewModel {
    let modelContainer: ModelContainer
    private var discovery: GoogleNewsDiscovery
    private(set) var isChecking = false

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.discovery = GoogleNewsDiscovery(modelContainer: modelContainer)
    }

    /// 新しいソースをチェック
    func checkForNewSources() async {
        isChecking = true
        defer { isChecking = false }
        await discovery.discoverNewSources()
    }

    /// 発見されたドメインをソースとして追加
    func acceptSource(_ domain: DiscoveredDomain) async {
        let context = modelContainer.mainContext
        let siteURL = URL(string: "https://\(domain.domain)")!

        // RSSが見つかっていなければ検出を試みる
        var feedURL = domain.detectedFeedURL
        if feedURL == nil {
            feedURL = await RSSDetector.detectFeed(from: siteURL)
            domain.detectedFeedURL = feedURL
        }

        guard let feedURL else {
            // RSSが見つからない場合は追加できない
            return
        }

        let source = Source(
            name: domain.domain,
            feedURL: feedURL,
            siteURL: siteURL,
            sourceType: .news,
            category: ""
        )
        context.insert(source)
        try? context.save()
    }

    /// ドメインを拒否
    func rejectSource(_ domain: DiscoveredDomain) {
        domain.isRejected = true
        try? modelContainer.mainContext.save()
    }
}
