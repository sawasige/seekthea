import Foundation
import SwiftData

@Observable
@MainActor
class DiscoveryViewModel {
    let modelContainer: ModelContainer
    private var discovery: GoogleNewsDiscovery
    private(set) var isChecking = false
    var statusMessage: String?

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.discovery = GoogleNewsDiscovery(modelContainer: modelContainer)
    }

    func checkForNewSources() async {
        isChecking = true
        defer {
            isChecking = false
            statusMessage = nil
        }
        await discovery.discoverNewSources { [weak self] message in
            Task { @MainActor in
                self?.statusMessage = message
            }
        }
    }

    func rejectSource(_ domain: DiscoveredDomain) {
        domain.isRejected = true
        try? modelContainer.mainContext.save()
    }
}
