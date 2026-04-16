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
    @State private var sourcesViewModel: SourcesViewModel?
    @State private var previewDomain: DiscoveredDomain?

    let modelContainer: ModelContainer

    var body: some View {
        List {
            if !suggestions.isEmpty {
                ForEach(suggestions, id: \.domain) { domain in
                    Button {
                        previewDomain = domain
                    } label: {
                        discoveryRow(domain)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button("スキップ", role: .destructive) {
                            viewModel?.rejectSource(domain)
                        }
                    }
                }
            }

            if suggestions.isEmpty && viewModel?.isChecking != true {
                ContentUnavailableView(
                    "新しいソースはまだありません",
                    systemImage: "sparkle.magnifyingglass",
                    description: Text("Google Newsから自動的にソースを発見します")
                )
            }
        }
        .overlay(alignment: .bottom) {
            if let status = viewModel?.statusMessage {
                HStack(spacing: 8) {
                    ProgressView()
                        #if !os(macOS)
                        .controlSize(.small)
                        #endif
                    Text(status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial)
                .clipShape(Capsule())
                .padding(.bottom, 8)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
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
        .sheet(item: $previewDomain) { domain in
            SourcePreviewView(mode: .discovered(domain), modelContainer: modelContainer)
        }
        .task {
            if viewModel == nil {
                viewModel = DiscoveryViewModel(modelContainer: modelContainer)
                sourcesViewModel = SourcesViewModel(modelContainer: modelContainer)
                await viewModel?.checkForNewSources()
            }
        }
    }

    private func discoveryRow(_ domain: DiscoveredDomain) -> some View {
        HStack(spacing: 12) {
            SourceThumbnailView(siteURL: URL(string: "https://\(domain.domain)")!, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(domain.feedTitle ?? domain.domain)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if domain.feedTitle != nil {
                    Text(domain.domain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("\(domain.mentionCount)回検出")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                Task { await sourcesViewModel?.acceptDiscoveredSource(domain) }
            } label: {
                Image(systemName: "plus.circle")
                    .foregroundStyle(Color.accentColor)
                    .font(.title3)
            }
            .buttonStyle(.plain)
        }
    }
}

