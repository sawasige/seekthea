import SwiftUI
import SwiftData

struct SourcesListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Source.addedAt) private var sources: [Source]
    @State private var viewModel: SourcesViewModel?
    @State private var selectedTab: Tab = .registered
    @State private var previewItem: PreviewItem?
    @State private var showManualAdd = false

    let modelContainer: ModelContainer

    enum Tab: String, CaseIterable {
        case registered = "登録済み"
        case add = "追加"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            if selectedTab == .registered {
                registeredView
            } else {
                addView
            }
        }
        #if os(macOS)
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
        #endif
        .navigationTitle("ソース管理")
        .toolbar {
            if selectedTab == .registered {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showManualAdd = true
                    } label: {
                        Image(systemName: "link.badge.plus")
                    }
                }
            }
        }
        .sheet(item: $previewItem) { item in
            SourcePreviewView(mode: item.mode, modelContainer: modelContainer)
        }
        .sheet(isPresented: $showManualAdd) {
            AddSourceView(modelContainer: modelContainer)
        }
        .task {
            if viewModel == nil {
                viewModel = SourcesViewModel(modelContainer: modelContainer)
            }
        }
    }

    // MARK: - 登録済みタブ

    private var registeredSourcesByCategory: [(String, [Source])] {
        let grouped = Dictionary(grouping: sources, by: { $0.category.isEmpty ? "その他" : $0.category })
        return PresetCatalog.categoryOrder.compactMap { cat in
            grouped[cat].map { (cat, $0) }
        } + grouped
            .filter { !PresetCatalog.categoryOrder.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    @ViewBuilder
    private var registeredView: some View {
        if sources.isEmpty {
            ContentUnavailableView(
                "ソースがありません",
                systemImage: "list.bullet.rectangle",
                description: Text("「追加」タブからソースを追加してください")
            )
        } else {
            List {
                ForEach(registeredSourcesByCategory, id: \.0) { category, sourcesInCategory in
                    DisclosureGroup(
                        content: {
                            ForEach(sourcesInCategory, id: \.id) { source in
                                Button {
                                    previewItem = PreviewItem(mode: .registered(source))
                                } label: {
                                    registeredRow(source)
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete { offsets in
                                for index in offsets {
                                    viewModel?.deleteSource(sourcesInCategory[index])
                                }
                            }
                        },
                        label: {
                            HStack {
                                Text(category).font(.headline)
                                Spacer()
                                Text("\(sourcesInCategory.count)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    )
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
        }
    }

    private func registeredRow(_ source: Source) -> some View {
        HStack(spacing: 12) {
            SourceThumbnailView(siteURL: source.siteURL, ogImageURL: source.ogImageURL, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if source.articleCount > 0 {
                        Text("\(source.articleCount)記事")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let lastFetched = source.lastFetchedAt {
                        Text(lastFetched, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { source.isActive },
                set: { _ in viewModel?.toggleSource(source) }
            ))
            .labelsHidden()
        }
    }

    // MARK: - 追加タブ

    @State private var searchText = ""

    private var filteredPresets: [(String, [PresetSource])] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return PresetCatalog.categoryOrder.compactMap { cat in
            guard let presets = PresetCatalog.shared[cat] else { return nil }
            let filtered = query.isEmpty ? presets : presets.filter {
                $0.name.lowercased().contains(query) || $0.category.lowercased().contains(query)
            }
            guard !filtered.isEmpty else { return nil }
            return (cat, filtered)
        }
    }

    private var addView: some View {
        List {
            ForEach(filteredPresets, id: \.0) { category, presets in
                DisclosureGroup(
                    content: {
                        ForEach(presets) { preset in
                            Button {
                                previewItem = PreviewItem(mode: .preset(preset))
                            } label: {
                                presetRow(preset)
                            }
                            .buttonStyle(.plain)
                        }
                    },
                    label: {
                        HStack {
                            Text(category).font(.headline)
                            Spacer()
                            Text("\(presets.count)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                )
            }
        }
        .searchable(text: $searchText, prompt: "ソースを検索")
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    private func presetRow(_ preset: PresetSource) -> some View {
        let isAdded = viewModel?.isAdded(preset) ?? false
        return HStack(spacing: 12) {
            SourceThumbnailView(siteURL: preset.siteURL, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(preset.siteURL.host() ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isAdded {
                Button {
                    viewModel?.removePresetSource(preset)
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    viewModel?.addPresetSource(preset)
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(Color.accentColor)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// Identifiableなラッパー（.sheet(item:)用）
private struct PreviewItem: Identifiable {
    let id = UUID()
    let mode: SourcePreviewView.Mode
}
