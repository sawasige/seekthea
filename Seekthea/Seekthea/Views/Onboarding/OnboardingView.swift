import SwiftUI
import SwiftData

extension Notification.Name {
    static let onboardingCompleted = Notification.Name("onboardingCompleted")
}

struct OnboardingView: View {
    let modelContainer: ModelContainer
    let onDismiss: () -> Void

    @State private var step: Step = .welcome
    @State private var viewModel: SourcesViewModel?
    @State private var addedCount = 0

    enum Step {
        case welcome
        case categoryPicker
        case done
    }

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                OnboardingWelcomeView(
                    onStart: { transition(to: .categoryPicker) },
                    onSkip: onDismiss
                )
                .transition(zoomCrossFade)

            case .categoryPicker:
                OnboardingCategoryPickerView(
                    onConfirm: { categories in
                        addCategories(categories)
                        transition(to: .done)
                    },
                    onBack: { transition(to: .welcome) }
                )
                .transition(zoomCrossFade)

            case .done:
                OnboardingDoneView(
                    addedCount: addedCount,
                    onDismiss: onDismiss
                )
                .transition(zoomCrossFade)
            }
        }
        .task {
            if viewModel == nil {
                viewModel = SourcesViewModel(modelContainer: modelContainer)
            }
        }
    }

    private var zoomCrossFade: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 1.05).combined(with: .opacity),
            removal: .scale(scale: 0.95).combined(with: .opacity)
        )
    }

    private func transition(to next: Step) {
        withAnimation(.easeInOut(duration: 0.45)) {
            step = next
        }
    }

    private func addCategories(_ categories: [String]) {
        guard let viewModel else { return }
        addedCount = viewModel.addPopularSources(forCategories: categories)
        // 追加後すぐにフィード取得を開始（裏で実行）。
        // 完了したらフィード側に通知を送って再読み込みさせる
        let container = modelContainer
        Task { @MainActor in
            await FeedFetcher(modelContainer: container).fetchAll()
            NotificationCenter.default.post(name: .onboardingCompleted, object: nil)
        }
    }
}
