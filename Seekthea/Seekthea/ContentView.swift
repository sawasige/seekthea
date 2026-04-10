import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var pendingSourceAlert = false
    @State private var pendingSources: [PendingSource] = []

    private var modelContainer: ModelContainer {
        modelContext.container
    }

    var body: some View {
        FeedView(modelContainer: modelContainer)
            .task {
                deduplicateSources()
                checkPendingSources()
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

    /// 重複を削除（CloudKit同期で発生しうる）
    private func deduplicateSources() {
        let sources = (try? modelContext.fetch(FetchDescriptor<Source>())) ?? []
        var seenSources = Set<URL>()
        for source in sources {
            if seenSources.contains(source.feedURL) {
                modelContext.delete(source)
            } else {
                seenSources.insert(source.feedURL)
            }
        }

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
