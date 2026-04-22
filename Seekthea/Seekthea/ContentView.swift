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
                checkPendingSources()
                await checkSyncAndSeed()
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

    /// CloudKit同期を待ってから seed と onboarding 判定を行う
    /// 待たずに seed すると複数端末で独立にデフォルト投入が走り、同期後に重複する
    private func checkSyncAndSeed() async {
        guard !didOnboardingCheck else { return }
        didOnboardingCheck = true
        try? await Task.sleep(for: .milliseconds(1500))
        // 同期で届いた重複を整理してから seed
        deduplicateSources()
        UserCategory.seedIfNeeded(context: modelContext)
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

        let discovered = (try? modelContext.fetch(
            FetchDescriptor<DiscoveredDomain>(sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
        )) ?? []
        var seenDomains: [String: DiscoveredDomain] = [:]
        for d in discovered {
            if let kept = seenDomains[d.domain] {
                kept.mentionCount += d.mentionCount
                if d.isRejected { kept.isRejected = true }
                if d.isSuggested && !kept.isSuggested {
                    kept.isSuggested = true
                    kept.detectedFeedURL = d.detectedFeedURL
                    kept.feedTitle = d.feedTitle
                }
                modelContext.delete(d)
            } else {
                seenDomains[d.domain] = d
            }
        }

        // 多端末で seedIfNeeded が同期前に独立に走ると、デフォルトカテゴリが N×10 個並ぶ
        let categories = (try? modelContext.fetch(
            FetchDescriptor<UserCategory>(sortBy: [SortDescriptor(\.addedAt)])
        )) ?? []
        var seenCategories = Set<String>()
        for cat in categories {
            let key = cat.name.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if seenCategories.contains(key) {
                modelContext.delete(cat)
            } else {
                seenCategories.insert(key)
            }
        }

        let interests = (try? modelContext.fetch(
            FetchDescriptor<UserInterest>(sortBy: [SortDescriptor(\.addedAt)])
        )) ?? []
        var seenInterests = Set<String>()
        for interest in interests {
            let key = interest.topic.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if seenInterests.contains(key) {
                modelContext.delete(interest)
            } else {
                seenInterests.insert(key)
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
