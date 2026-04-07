import SwiftUI
import SwiftData

struct DiscoveryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        filter: #Predicate<DiscoveredDomain> { $0.isSuggested && !$0.isRejected && $0.detectedFeedURL != nil },
        sort: \DiscoveredDomain.mentionCount,
        order: .reverse
    ) private var suggestions: [DiscoveredDomain]


    @State private var viewModel: DiscoveryViewModel?

    let modelContainer: ModelContainer

    var body: some View {
            List {
                if !suggestions.isEmpty {
                    Section("新しいソース候補") {
                        ForEach(suggestions, id: \.domain) { domain in
                            SourceSuggestionCard(
                                domain: domain,
                                onAccept: { viewModel?.acceptSource(domain) },
                                onReject: { viewModel?.rejectSource(domain) }
                            )
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowSeparator(.hidden)
                        }
                    }
                }

                if suggestions.isEmpty {
                    ContentUnavailableView(
                        "新しいソースはまだありません",
                        systemImage: "sparkle.magnifyingglass",
                        description: Text("Google Newsから自動的にソースを発見します")
                    )
                }
            }
            .listStyle(.plain)
            #if os(macOS)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            #endif
            .navigationTitle("発見")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task {
                            await viewModel?.checkForNewSources()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel?.isChecking ?? false)
                }
            }
            .task {
                if viewModel == nil {
                    viewModel = DiscoveryViewModel(modelContainer: modelContainer)
                    await viewModel?.checkForNewSources()
                }
            }
    }
}
