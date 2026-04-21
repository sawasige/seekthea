import SwiftUI
import SwiftData

struct SourcesListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Source.addedAt) private var sources: [Source]
    @State private var viewModel: SourcesViewModel?
    @State private var previewItem: PreviewItem?
    @State private var showManualAdd = false
    @State private var searchText = ""
    @State private var deleteTarget: Source?

    let modelContainer: ModelContainer

    /// 手動追加（プリセット外）ソース（検索フィルタ済み）
    private var manualSources: [Source] {
        let all = sources.filter { !$0.isPreset }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.name.lowercased().contains(query)
                || ($0.siteURL.host()?.lowercased().contains(query) ?? false)
        }
    }

    /// カテゴリ別プリセット一覧（検索フィルタ済み）
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

    /// カテゴリ内の登録済み数
    private func registeredCount(in presets: [PresetSource]) -> Int {
        presets.filter { viewModel?.isAdded($0) ?? false }.count
    }

    var body: some View {
        List {
            // 手動追加ソースセクション
            if !manualSources.isEmpty {
                Section("手動追加") {
                    ForEach(manualSources, id: \.id) { source in
                        Button {
                            previewItem = PreviewItem(mode: .registered(source))
                        } label: {
                            manualSourceRow(source)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // プリセットカタログ
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
                            let registered = registeredCount(in: presets)
                            Text("\(registered)/\(presets.count)")
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
        #if os(macOS)
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
        #endif
        .navigationTitle("ソース管理")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    showManualAdd = true
                } label: {
                    Image(systemName: "link.badge.plus")
                }
            }
        }
        .sheet(item: $previewItem) { item in
            SourcePreviewView(mode: item.mode, modelContainer: modelContainer)
        }
        .sheet(isPresented: $showManualAdd) {
            AddSourceView(modelContainer: modelContainer)
        }
        .alert("ソースを削除", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("削除", role: .destructive) {
                if let source = deleteTarget {
                    viewModel?.deleteSource(source)
                    deleteTarget = nil
                }
            }
            Button("キャンセル", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            if let source = deleteTarget {
                Text("\(source.name) を削除しますか？手動追加したソースは再登録にURLの入力が必要です。")
            }
        }
        .task {
            if viewModel == nil {
                viewModel = SourcesViewModel(modelContainer: modelContainer)
            }
        }
        .onChange(of: sources.count) {
            // プレビュー画面など別経路で追加/削除されたら一覧の登録状態キャッシュを更新
            viewModel?.refreshRegisteredURLs()
        }
    }

    // MARK: - 手動追加ソース行

    private func manualSourceRow(_ source: Source) -> some View {
        HStack(spacing: 12) {
            SourceThumbnailView(siteURL: source.siteURL, ogImageURL: source.ogImageURL, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(source.siteURL.host() ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { source.isActive },
                set: { _ in viewModel?.toggleSource(source) }
            ))
            .labelsHidden()
            Button {
                deleteTarget = source
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - プリセット行

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
                    #if os(iOS)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    #endif
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, .green)
                        .font(.title)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    viewModel?.addPresetSource(preset)
                    #if os(iOS)
                    UISelectionFeedbackGenerator().selectionChanged()
                    #endif
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.white, Color.accentColor)
                        .font(.title)
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
