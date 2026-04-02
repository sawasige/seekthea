import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var pendingSourceAlert = false
    @State private var pendingSources: [PendingSource] = []
    @State private var newPresets: [RemotePresetSource] = []
    @State private var showPresetAlert = false

    private var modelContainer: ModelContainer {
        modelContext.container
    }

    var body: some View {
        TabView {
            FeedView(modelContainer: modelContainer)
                .tabItem {
                    Label("フィード", systemImage: "newspaper")
                }

            DiscoveryView(modelContainer: modelContainer)
                .tabItem {
                    Label("発見", systemImage: "sparkle.magnifyingglass")
                }

            SourcesListView(modelContainer: modelContainer)
                .tabItem {
                    Label("ソース", systemImage: "list.bullet")
                }

            SettingsView()
                .tabItem {
                    Label("設定", systemImage: "gear")
                }
        }
        .task {
            // 重複ソースを削除
            deduplicateSources()

            // プリセット読み込み
            do {
                try PresetLoader.loadIfNeeded(context: modelContext)
            } catch {
                print("Failed to load presets: \(error)")
            }

            // Share Extensionからのpending sources確認
            checkPendingSources()

            // Remote Presetの更新チェック
            await checkRemotePresets()
        }
        .alert("新しいソースが共有されました", isPresented: $pendingSourceAlert) {
            Button("追加") {
                addPendingSources()
            }
            Button("キャンセル", role: .cancel) {
                PendingSourcesStore.clear()
            }
        } message: {
            let names = pendingSources.compactMap(\.title).joined(separator: ", ")
            Text("\(names) をソースに追加しますか？")
        }
        .alert("新しいプリセットソース", isPresented: $showPresetAlert) {
            Button("すべて追加") {
                addRemotePresets()
            }
            Button("後で", role: .cancel) {}
        } message: {
            let names = newPresets.map(\.name).joined(separator: ", ")
            Text("\(names) が利用可能です")
        }
    }

    private func checkPendingSources() {
        let sources = PendingSourcesStore.load()
        if !sources.isEmpty {
            pendingSources = sources
            pendingSourceAlert = true
        }
    }

    private func addPendingSources() {
        for pending in pendingSources {
            if let feedURL = pending.detectedFeedURL {
                let source = Source(
                    name: pending.title ?? pending.url.host() ?? "Unknown",
                    feedURL: feedURL,
                    siteURL: pending.url,
                    sourceType: .news
                )
                modelContext.insert(source)
            }
        }
        try? modelContext.save()
        PendingSourcesStore.clear()
    }

    private func checkRemotePresets() async {
        let service = RemotePresetService(modelContainer: modelContainer)
        let presets = await service.checkForUpdates()
        if !presets.isEmpty {
            newPresets = presets
            showPresetAlert = true
        }
    }

    private func addRemotePresets() {
        let service = RemotePresetService(modelContainer: modelContainer)
        for preset in newPresets {
            service.addSource(preset)
        }
    }

    /// 重複を削除（CloudKit同期で発生しうる）
    private func deduplicateSources() {
        // ソースの重複削除
        let sources = (try? modelContext.fetch(FetchDescriptor<Source>())) ?? []
        var seenSources = Set<URL>()
        for source in sources {
            if seenSources.contains(source.feedURL) {
                modelContext.delete(source)
            } else {
                seenSources.insert(source.feedURL)
            }
        }

        // 記事の重複削除
        let articles = (try? modelContext.fetch(FetchDescriptor<Article>())) ?? []
        var seenArticles = Set<URL>()
        for article in articles {
            if seenArticles.contains(article.articleURL) {
                modelContext.delete(article)
            } else {
                seenArticles.insert(article.articleURL)
            }
        }

        try? modelContext.save()
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Source.self, Article.self, DiscoveredDomain.self], inMemory: true)
}
