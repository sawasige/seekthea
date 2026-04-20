import SwiftUI
import SwiftData

struct DiscoveryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        filter: #Predicate<DiscoveredDomain> { $0.isSuggested && !$0.isRejected && $0.detectedFeedURL != nil },
        sort: \DiscoveredDomain.lastSeenAt,
        order: .reverse
    ) private var suggestions: [DiscoveredDomain]

    @AppStorage("lastDiscoveryCheckedAt") private var lastCheckedTimestamp: Double = 0
    @State private var checkedAtSnapshot: Date?
    @State private var sourcesViewModel: SourcesViewModel?
    @State private var previewDomain: DiscoveredDomain?

    let modelContainer: ModelContainer

    private var sortedSuggestions: [DiscoveredDomain] {
        suggestions.sorted {
            if $0.lastSeenAt != $1.lastSeenAt {
                return $0.lastSeenAt > $1.lastSeenAt
            }
            return $0.mentionCount > $1.mentionCount
        }
    }

    private var newSuggestions: [DiscoveredDomain] {
        guard let snapshot = checkedAtSnapshot else { return [] }
        return sortedSuggestions.filter { $0.lastSeenAt > snapshot }
    }

    private var pastSuggestions: [DiscoveredDomain] {
        guard let snapshot = checkedAtSnapshot else { return sortedSuggestions }
        return sortedSuggestions.filter { $0.lastSeenAt <= snapshot }
    }

    var body: some View {
        List {
            if !newSuggestions.isEmpty {
                Section("新着") {
                    ForEach(newSuggestions, id: \.domain) { domain in
                        cardRow(domain)
                    }
                }
                if !pastSuggestions.isEmpty {
                    Section("これまでの発見") {
                        ForEach(pastSuggestions, id: \.domain) { domain in
                            cardRow(domain)
                        }
                    }
                }
            } else {
                ForEach(sortedSuggestions, id: \.domain) { domain in
                    cardRow(domain)
                }
            }

            if sortedSuggestions.isEmpty {
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
                    DiscoveryManager.shared.runIfNeeded()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(DiscoveryManager.shared.isRunning)
            }
        }
        .overlay(alignment: .bottom) {
            if let status = DiscoveryManager.shared.statusMessage {
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
        .sheet(item: $previewDomain) { domain in
            SourcePreviewView(mode: .discovered(domain), modelContainer: modelContainer)
        }
        .task {
            if sourcesViewModel == nil {
                sourcesViewModel = SourcesViewModel(modelContainer: modelContainer)
            }
            if checkedAtSnapshot == nil {
                checkedAtSnapshot = Date(timeIntervalSince1970: lastCheckedTimestamp)
            }
            DiscoveryManager.shared.markAsChecked()
            DiscoveryManager.shared.runIfDue(interval: 10800) // 3時間
        }
        .onDisappear {
            DiscoveryManager.shared.markAsChecked()
        }
    }

    @ViewBuilder
    private func cardRow(_ domain: DiscoveredDomain) -> some View {
        Button {
            previewDomain = domain
        } label: {
            cardContent(domain)
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing) {
            Button("スキップ", role: .destructive) {
                domain.isRejected = true
                try? modelContext.save()
            }
        }
    }

    private func cardContent(_ domain: DiscoveredDomain) -> some View {
        HStack(alignment: .center, spacing: 14) {
            SourceThumbnailView(siteURL: URL(string: "https://\(domain.domain)")!, size: 56)

            let displayTitle = domain.feedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle?.isEmpty == false ? displayTitle! : domain.domain)
                    .font(.headline)
                    .lineLimit(1)

                if displayTitle?.isEmpty == false {
                    Text(domain.domain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Image(systemName: "sparkle.magnifyingglass")
                    Text(relativeDate(domain.lastSeenAt))
                    Text("·")
                    Text("\(domain.mentionCount)回検出")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }

            Spacer()

            Button {
                Task { await sourcesViewModel?.acceptDiscoveredSource(domain) }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.white, Color.accentColor)
                    .font(.title)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func relativeDate(_ date: Date) -> String {
        let interval = -date.timeIntervalSinceNow
        if interval < 60 { return "たった今" }
        if interval < 3600 { return "\(Int(interval / 60))分前" }
        if interval < 86400 { return "\(Int(interval / 3600))時間前" }
        if interval < 604800 { return "\(Int(interval / 86400))日前" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }
}
