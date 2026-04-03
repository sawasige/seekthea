import SwiftUI
import SwiftData

enum FeedMode: String, CaseIterable {
    case forYou = "おすすめ"
    case latest = "新着"
}

// MARK: - 記事グリッド（スクロール状態に依存しない）

private struct ArticleGridView: View {
    let articles: [Article]
    let showScore: Bool
    let columns: [GridItem]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(articles, id: \.id) { article in
                NavigationLink {
                    ArticleDetailView(article: article)
                } label: {
                    ArticleCardView(article: article, showScore: showScore)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 20)
    }
}

// MARK: - FeedView

struct FeedView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Article.publishedAt, order: .reverse) private var allArticles: [Article]
    @State private var viewModel: FeedViewModel?
    @State private var feedMode: FeedMode = .forYou
    @State private var selectedCategory: String? = nil
    @State private var hideAmount: CGFloat = 0
    @State private var lastScrollY: CGFloat = 0
    @State private var currentScrollY: CGFloat = 0
    @State private var topInset: CGFloat = 0
    @State private var cachedArticles: [Article] = []
    @State private var cachedCategoryCounts: [String: Int] = [:]

    let modelContainer: ModelContainer

    private let headerHeight: CGFloat = 90
    private var fullHideAmount: CGFloat { -(headerHeight + topInset) }

    private var headerOffset: CGFloat {
        currentScrollY + hideAmount
    }

    private func updateCachedData() {
        let activeFeedURLs = viewModel?.activeSourceFeedURLs() ?? []

        var counts: [String: Int] = [:]
        for article in allArticles where activeFeedURLs.contains(article.sourceFeedURL) {
            for cat in article.categories {
                counts[cat, default: 0] += 1
            }
        }
        cachedCategoryCounts = counts

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

        cachedArticles = articles
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var columns: [GridItem] {
        #if os(macOS)
        [GridItem(.adaptive(minimum: 280, maximum: 400), spacing: 16)]
        #else
        if horizontalSizeClass == .regular {
            [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 12)]
        } else {
            [GridItem(.flexible())]
        }
        #endif
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // ヘッダー
                    VStack(spacing: 0) {
                        Picker("モード", selection: $feedMode) {
                            ForEach(FeedMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .padding(.top, 4)

                        CategoryFilterView(selectedCategory: $selectedCategory, categoryCounts: cachedCategoryCounts)
                            .padding(.vertical, 6)
                    }
                    .frame(height: headerHeight)
                    .background(alignment: .top) {
                        #if os(macOS)
                        Color(nsColor: .windowBackgroundColor)
                            .frame(height: headerHeight + 500)
                            .offset(y: -500)
                        #else
                        Color(uiColor: .systemBackground)
                            .frame(height: headerHeight + 500)
                            .offset(y: -500)
                        #endif
                    }
                    .onGeometryChange(for: CGFloat.self) { geo in
                        geo.frame(in: .global).minY
                    } action: { minY in
                        if topInset == 0 && minY > 0 { topInset = minY }
                    }
                    .offset(y: headerOffset)
                    .zIndex(1)

                    // 記事グリッド（別View、スクロール状態で再描画されない）
                    ArticleGridView(
                        articles: cachedArticles,
                        showScore: feedMode == .forYou,
                        columns: columns
                    )
                }
            }
            .contentMargins(.top, headerHeight, for: .scrollIndicators)
            .refreshable {
                await refreshAll()
            }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, newValue in
                currentScrollY = newValue

                let clampedNew = max(0, newValue)
                let clampedOld = max(0, lastScrollY)
                lastScrollY = newValue

                let delta = clampedNew - clampedOld
                guard abs(delta) > 0.5 else { return }

                if delta > 0 {
                    hideAmount = max(fullHideAmount, hideAmount - delta)
                } else {
                    hideAmount = min(0, hideAmount - delta)
                }
            }
            .onScrollPhaseChange { _, newPhase in
                if newPhase == .idle {
                    withAnimation(.snappy(duration: 0.2)) {
                        hideAmount = hideAmount < fullHideAmount * 0.5 ? fullHideAmount : 0
                    }
                }
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
            .onChange(of: feedMode) { updateCachedData() }
            .onChange(of: selectedCategory) { updateCachedData() }
            .onChange(of: allArticles.count) { updateCachedData() }
            .navigationTitle("Seekthea")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
                updateCachedData()
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
        updateCachedData()
    }
}
