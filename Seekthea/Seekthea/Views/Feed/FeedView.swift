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
    @State private var selectedCategory: String? = nil

    let modelContainer: ModelContainer

    private var categoryCounts: [String: Int] {
        let activeFeedURLs = viewModel?.activeSourceFeedURLs() ?? []
        var counts: [String: Int] = [:]
        for article in allArticles where activeFeedURLs.contains(article.sourceFeedURL) {
            for cat in article.categories {
                counts[cat, default: 0] += 1
            }
        }
        return counts
    }

    private var displayArticles: [Article] {
        let activeFeedURLs = viewModel?.activeSourceFeedURLs() ?? []

        var articles = allArticles.filter { article in
            guard activeFeedURLs.contains(article.sourceFeedURL) else { return false }
            if let cat = selectedCategory {
                if !article.categories.contains(cat) { return false }
            }
            return true
        }

        if feedMode == .forYou {
            articles.sort { a, b in
                if abs(a.relevanceScore - b.relevanceScore) > 0.01 {
                    return a.relevanceScore > b.relevanceScore
                }
                return (a.publishedAt ?? .distantPast) > (b.publishedAt ?? .distantPast)
            }
        }

        return articles
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var columns: [GridItem] {
        #if os(macOS)
        [GridItem(.adaptive(minimum: 280, maximum: 400), spacing: 16)]
        #else
        if horizontalSizeClass == .regular {
            // iPad
            [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 12)]
        } else {
            // iPhone: 1カラム
            [GridItem(.flexible())]
        }
        #endif
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
                CategoryFilterView(selectedCategory: $selectedCategory, categoryCounts: categoryCounts)
                    .padding(.vertical, 8)

                // 記事タイルグリッド
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(displayArticles, id: \.id) { article in
                            NavigationLink {
                                ArticleDetailView(article: article)
                            } label: {
                                ArticleCardView(article: article, showScore: feedMode == .forYou)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
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
                await viewModel?.refresh()
                viewModel?.updateRelevanceScores()
            }
            .onAppear {
                if viewModel != nil {
                    Task { await refreshAll() }
                }
            }
        }
    }

    private func refreshAll() async {
        await viewModel?.refresh()
        viewModel?.updateRelevanceScores()
        viewModel?.classifyInBackground()
    }
}
