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

    func checkForNewSources() async {
        isChecking = true
        defer { isChecking = false }
        await discovery.discoverNewSources()
    }

    /// 発見されたドメインをソースとして追加
    func acceptSource(_ domain: DiscoveredDomain) {
        guard let feedURL = domain.detectedFeedURL else { return }
        let context = modelContainer.mainContext
        let siteURL = URL(string: "https://\(domain.domain)")!

        let source = Source(
            name: domain.domain,
            feedURL: feedURL,
            siteURL: siteURL,
            sourceType: .news,
            category: ""
        )
        context.insert(source)
        domain.isRejected = true
        try? context.save()
    }

    func rejectSource(_ domain: DiscoveredDomain) {
        domain.isRejected = true
        try? modelContainer.mainContext.save()
    }
}
