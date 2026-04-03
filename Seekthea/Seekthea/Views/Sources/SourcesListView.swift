import SwiftUI
import SwiftData

struct SourcesListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Source.addedAt) private var sources: [Source]
    @State private var viewModel: SourcesViewModel?
    @State private var showAddSheet = false
    @State private var selectedTab: SourceType = .news

    let modelContainer: ModelContainer

    private var filteredSources: [Source] {
        sources.filter { $0.sourceTypeEnum == selectedTab }
    }

    var body: some View {
            VStack(spacing: 0) {
                Picker("種別", selection: $selectedTab) {
                    ForEach(SourceType.allCases.filter { $0 != .discovery }, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                List {
                    ForEach(filteredSources, id: \.id) { source in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name)
                                    .font(.headline)
                                HStack(spacing: 8) {
                                    Text(source.category)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if source.articleCount > 0 {
                                        Text("\(source.articleCount)記事")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
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
                    .onDelete { offsets in
                        for index in offsets {
                            viewModel?.deleteSource(filteredSources[index])
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #endif
            }
            #if os(macOS)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            #endif
            .navigationTitle("ソース管理")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddSourceView(modelContainer: modelContainer)
            }
            .task {
                if viewModel == nil {
                    viewModel = SourcesViewModel(modelContainer: modelContainer)
                }
            }
    }
}
