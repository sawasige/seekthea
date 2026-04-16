import SwiftUI
import SwiftData
import CoreData

@main
struct SeektheaApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Source.self,
            Article.self,
            DiscoveredDomain.self,
            UserInterest.self,
            UserCategory.self,
        ])

        // CloudKit同期を試みる → 失敗したらローカルのみで動作
        if let container = try? ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .automatic
            )]
        ) {
            return container
        }

        // ローカルのみ（古いストア削除してリトライ）
        let localConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )

        if let container = try? ModelContainer(for: schema, configurations: [localConfig]) {
            return container
        }

        // 既存ストアが壊れている場合は削除して再作成
        let urls = [
            localConfig.url,
            localConfig.url.appendingPathExtension("wal"),
            localConfig.url.appendingPathExtension("shm"),
        ]
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }

        do {
            return try ModelContainer(for: schema, configurations: [localConfig])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // フォアグラウンド復帰時にCloudKit同期を促す
                let context = sharedModelContainer.mainContext
                try? context.save()
            }
        }
    }
}
