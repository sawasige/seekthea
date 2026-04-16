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

    func rejectSource(_ domain: DiscoveredDomain) {
        domain.isRejected = true
        try? modelContainer.mainContext.save()
    }
}
