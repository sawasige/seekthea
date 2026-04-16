import Foundation
import SwiftData
import FeedKit

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
    func acceptSource(_ domain: DiscoveredDomain) async {
        guard let feedURL = domain.detectedFeedURL else { return }
        let context = modelContainer.mainContext
        let siteURL = URL(string: "https://\(domain.domain)")!

        var name = domain.domain
        if let title = domain.feedTitle {
            name = title
        } else if let title = await parseFeedTitle(url: feedURL) {
            name = title
        }
        let source = Source(
            name: name,
            feedURL: feedURL,
            siteURL: siteURL
        )
        context.insert(source)
        domain.isRejected = true
        try? context.save()
    }

    private func parseFeedTitle(url: URL) async -> String? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let parser = FeedKit.FeedParser(data: data)
        guard case .success(let feed) = parser.parse() else { return nil }
        switch feed {
        case .rss(let rss): return rss.title
        case .atom(let atom): return atom.title
        case .json(let json): return json.title
        }
    }

    func rejectSource(_ domain: DiscoveredDomain) {
        domain.isRejected = true
        try? modelContainer.mainContext.save()
    }
}
