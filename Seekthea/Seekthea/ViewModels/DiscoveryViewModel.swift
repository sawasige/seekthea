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
    func acceptSource(_ domain: DiscoveredDomain) {
        guard let feedURL = domain.detectedFeedURL else { return }
        let context = modelContainer.mainContext
        let source = Source(
            name: domain.domain,
            feedURL: feedURL,
            siteURL: URL(string: "https://\(domain.domain)")!,
            sourceType: .news,
            category: ""
        )
        context.insert(source)
        domain.isSuggested = true
        try? context.save()
    }

    /// ドメインを拒否
    func rejectSource(_ domain: DiscoveredDomain) {
        domain.isRejected = true
        try? modelContainer.mainContext.save()
    }
}
