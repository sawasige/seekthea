import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var sources: [Source]
    @State private var pendingSourceAlert = false
    @State private var pendingSources: [PendingSource] = []
    @State private var showOnboarding = false
    @State private var didOnboardingCheck = false

    private var modelContainer: ModelContainer {
        modelContext.container
    }

    var body: some View {
        FeedView(modelContainer: modelContainer)
            .task {
                deduplicateSources()
                UserCategory.seedIfNeeded(context: modelContext)
                checkPendingSources()
                await checkOnboarding()
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
            .modifier(OnboardingPresenter(
                isPresented: $showOnboarding,
                modelContainer: modelContainer
            ))
    }

    private func checkOnboarding() async {
        guard !didOnboardingCheck else { return }
        didOnboardingCheck = true
        // CloudKit 同期を待つため少し遅延
        try? await Task.sleep(for: .milliseconds(1500))
        if sources.isEmpty {
            showOnboarding = true
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
                    siteURL: pending.url
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

private struct OnboardingPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let modelContainer: ModelContainer

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: $isPresented) {
            OnboardingView(
                modelContainer: modelContainer,
                onDismiss: { isPresented = false }
            )
        }
        #else
        content.sheet(isPresented: $isPresented) {
            OnboardingView(
                modelContainer: modelContainer,
                onDismiss: { isPresented = false }
            )
            .frame(minWidth: 520, minHeight: 680)
            .interactiveDismissDisabled()
        }
        #endif
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Source.self, Article.self, DiscoveredDomain.self], inMemory: true)
}
