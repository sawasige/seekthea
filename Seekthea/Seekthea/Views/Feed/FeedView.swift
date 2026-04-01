import SwiftUI
import SwiftData

enum FeedMode: String, CaseIterable {
    case forYou = "おすすめ"
    case latest = "新着"
}

struct FeedView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Article.publishedAt, order: .reverse) private var allArticles: [Article]
    @State private var viewModel: FeedViewModel?
    @State private var feedMode: FeedMode = .forYou
    @State private var selectedSourceType: SourceType? = nil
    @State private var selectedCategory: ContentCategory? = nil

    let modelContainer: ModelContainer

    private var displayArticles: [Article] {
        var articles = allArticles.filter { article in
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

        if feedMode == .forYou {
            // 興味スコア順（スコア同じなら新しい順）
            articles.sort { a, b in
                if abs(a.relevanceScore - b.relevanceScore) > 0.01 {
                    return a.relevanceScore > b.relevanceScore
                }
                return (a.publishedAt ?? .distantPast) > (b.publishedAt ?? .distantPast)
            }
        }
        // .latest はQuery既定の publishedAt desc

        return articles
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // おすすめ / 新着 切り替え
                Picker("モード", selection: $feedMode) {
                    ForEach(FeedMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
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
                    ForEach(displayArticles, id: \.id) { article in
                        NavigationLink {
                            ArticleDetailView(article: article)
                        } label: {
                            ArticleCardView(article: article, showScore: feedMode == .forYou)
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await refreshAll()
                }
                .overlay {
                    if allArticles.isEmpty {
                        if viewModel == nil {
                            ProgressView("読み込み中...")
                        } else {
                            ContentUnavailableView(
                                "記事がありません",
                                systemImage: "newspaper",
                                description: Text("更新ボタンを押してください")
                            )
                        }
                    }
                }
            }
            .navigationTitle("フィード")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task { await refreshAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel?.isLoading ?? false)
                }
            }
            .task {
                if viewModel == nil {
                    viewModel = FeedViewModel(modelContainer: modelContainer)
                }
                await refreshAll()
            }
        }
    }

    private func refreshAll() async {
        await viewModel?.refresh()
        await viewModel?.enrichVisibleArticles(Array(displayArticles.prefix(20)))
        await viewModel?.processUnanalyzedArticles(displayArticles)
        viewModel?.updateRelevanceScores()
    }
}
