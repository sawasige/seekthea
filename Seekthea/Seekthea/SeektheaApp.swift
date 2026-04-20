import SwiftUI
import SwiftData

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
            Task { @MainActor in CloudSyncStatus.shared.setContainerInitialized(cloudKitEnabled: true) }
            return container
        }

        // ローカルのみ（古いストア削除してリトライ）
        let localConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )

        if let container = try? ModelContainer(for: schema, configurations: [localConfig]) {
            Task { @MainActor in CloudSyncStatus.shared.setContainerInitialized(cloudKitEnabled: false) }
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
            let container = try ModelContainer(for: schema, configurations: [localConfig])
            Task { @MainActor in CloudSyncStatus.shared.setContainerInitialized(cloudKitEnabled: false) }
            return container
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

                // 24時間に1回バックグラウンドでソース発見
                DiscoveryManager.shared.setup(modelContainer: sharedModelContainer)
                DiscoveryManager.shared.runIfDue()

                // 24時間に1回古い記事をクリーンアップ
                ArticleCleanupService.shared.runIfDue(modelContainer: sharedModelContainer)

                // iCloudアカウント状態をチェック
                Task { await CloudSyncStatus.shared.refresh() }
            }
        }
    }
}
