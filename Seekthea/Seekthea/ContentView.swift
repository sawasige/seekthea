import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var sources: [Source]
    @State private var showOnboarding = false
    @State private var didOnboardingCheck = false

    private var modelContainer: ModelContainer {
        modelContext.container
    }

    var body: some View {
        FeedView(modelContainer: modelContainer)
            .task {
                CloudSyncObserver.shared.setup(modelContainer: modelContainer)
                await DataDeduplicator.run(in: modelContext)
                await checkSyncAndSeed()
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
        await DataDeduplicator.run(in: modelContext)
        UserCategory.seedIfNeeded(context: modelContext)
        // aiHint フィールド追加前から使っている既存ユーザーへの backfill
        UserCategory.backfillHintsIfNeeded(context: modelContext)
        if sources.isEmpty {
            showOnboarding = true
        }
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
