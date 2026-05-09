import SwiftUI
import SwiftData

@main
struct SeektheaApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("feedMode") private var feedMode: FeedMode = .forYou
    @AppStorage("useCompactLayout") private var useCompactLayout = false

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Source.self,
            Article.self,
            DiscoveredDomain.self,
            UserInterest.self,
            UserCategory.self,
            ExcludedKeyword.self,
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
            // CloudSyncObserver の通知購読を ModelContainer 作成直後に同期で行う。
            // ContentView.task まで遅延させると、初回 install/reinstall 直後の
            // setup/import イベントを取りこぼして「同期中」ステータスが
            // 表示されないことがある。SwiftUI App の static let 初期化は
            // main thread なので MainActor.assumeIsolated で OK。
            MainActor.assumeIsolated {
                CloudSyncStatus.shared.setContainerInitialized(cloudKitEnabled: true)
                CloudSyncObserver.shared.setup(modelContainer: container)
            }
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
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            if newPhase == .active {
                // フォアグラウンド復帰時にCloudKit同期を促す
                let context = sharedModelContainer.mainContext
                try? context.save()

                // 24時間に1回バックグラウンドでソース発見
                DiscoveryManager.shared.setup(modelContainer: sharedModelContainer)
                DiscoveryManager.shared.runIfDue()

                // 古い記事をクリーンアップ
                Task { await ArticleCleanupService.shared.run(modelContainer: sharedModelContainer) }

                // iCloudアカウント状態をチェック
                Task { await CloudSyncStatus.shared.refresh() }
            }
        }
        .commands {
            // File > New (⌘N) は本アプリに「新規作成」概念が無いので隠す
            CommandGroup(replacing: .newItem) { }
            CommandMenu("表示") {
                Button("更新") {
                    NotificationCenter.default.post(name: .refreshFeedRequested, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button("おすすめ") { feedMode = .forYou }
                    .keyboardShortcut("1", modifiers: .command)
                Button("新着") { feedMode = .latest }
                    .keyboardShortcut("2", modifiers: .command)
                Button("お気に入り") { feedMode = .favorites }
                    .keyboardShortcut("3", modifiers: .command)
                Button("閲覧履歴") { feedMode = .history }
                    .keyboardShortcut("4", modifiers: .command)

                Divider()

                Button(useCompactLayout ? "通常レイアウト" : "コンパクトレイアウト") {
                    useCompactLayout.toggle()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
    }
}
