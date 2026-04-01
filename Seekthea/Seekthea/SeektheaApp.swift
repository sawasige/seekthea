import SwiftUI
import SwiftData

@main
struct SeektheaApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Source.self,
            Article.self,
            DiscoveredDomain.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .automatic
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
