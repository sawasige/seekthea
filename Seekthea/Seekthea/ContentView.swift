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
                DataDeduplicator.run(in: modelContext)
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
        DataDeduplicator.run(in: modelContext)
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
