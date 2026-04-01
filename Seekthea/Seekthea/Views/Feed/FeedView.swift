import SwiftUI
import SwiftData

struct FeedView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Article.publishedAt, order: .reverse) private var allArticles: [Article]
    @State private var viewModel: FeedViewModel?
    @State private var selectedSourceType: SourceType? = nil
    @State private var selectedCategory: ContentCategory? = nil

    let modelContainer: ModelContainer

    private var filteredArticles: [Article] {
        allArticles.filter { article in
            if let type = selectedSourceType, article.source?.sourceTypeEnum != type {
                return false
            }
            if let cat = selectedCategory, cat != .all {
                let catRaw = cat.rawValue
                if article.aiCategory != catRaw && article.source?.category != catRaw {
                    return false
                }
            }
            return true
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ソース種別セグメント
                Picker("種別", selection: $selectedSourceType) {
                    Text("全て").tag(SourceType?.none)
                    ForEach(SourceType.allCases.filter { $0 != .discovery }, id: \.self) { type in
                        Text(type.rawValue).tag(SourceType?.some(type))
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                // カテゴリフィルタ
                CategoryFilterView(selectedCategory: $selectedCategory)
                    .padding(.vertical, 8)

                // 記事リスト
                List {
                    ForEach(filteredArticles, id: \.id) { article in
                        NavigationLink {
                            ArticleDetailView(article: article)
                        } label: {
                            ArticleCardView(article: article)
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await viewModel?.refresh()
                    await viewModel?.enrichVisibleArticles(Array(filteredArticles.prefix(20)))
                    await viewModel?.processUnanalyzedArticles(Array(filteredArticles.prefix(20)))
                }
                .overlay {
                    if allArticles.isEmpty && viewModel != nil {
                        ContentUnavailableView(
                            "記事がありません",
                            systemImage: "newspaper",
                            description: Text("下に引いて更新してください")
                        )
                    }
                }
            }
            .navigationTitle("フィード")
            .task {
                if viewModel == nil {
                    viewModel = FeedViewModel(modelContainer: modelContainer)
                }
                await viewModel?.refresh()
                await viewModel?.enrichVisibleArticles(Array(filteredArticles.prefix(10)))
                await viewModel?.processUnanalyzedArticles(Array(filteredArticles.prefix(10)))
            }
        }
    }
}
