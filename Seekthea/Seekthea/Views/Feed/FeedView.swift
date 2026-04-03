import SwiftUI
import SwiftData

enum FeedMode: String, CaseIterable {
    case forYou = "おすすめ"
    case latest = "新着"
    case favorites = "お気に入り"
    case history = "閲覧履歴"
}

// MARK: - UIKit横スワイプ検知

#if !os(macOS)

private class SwipeInstallerView: UIView {
    var install: ((UIView) -> Void)?
    private var installed = false
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !installed else { return }
        tryInstall(retries: 5)
    }
    private func tryInstall(retries: Int) {
        guard retries > 0, !installed else { return }
        if superview != nil {
            installed = true
            install?(self)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.tryInstall(retries: retries - 1)
            }
        }
    }
}

private struct ScrollViewSwipeHelper: UIViewRepresentable {
    let onSwipeLeft: () -> Void
    let onSwipeRight: () -> Void
    @Binding var isSwiping: Bool
    @Binding var swipeProgress: CGFloat
    @Binding var swipeDirection: CGFloat

    func makeUIView(context: Context) -> UIView {
        let view = SwipeInstallerView()
        view.backgroundColor = .clear
        view.install = { installerView in
            guard context.coordinator.addedTo == nil else { return }
            guard let scrollView = Self.findScrollView(from: installerView) else { return }

            let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
            pan.delegate = context.coordinator
            scrollView.addGestureRecognizer(pan)
            context.coordinator.addedTo = scrollView
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onSwipeLeft = onSwipeLeft
        context.coordinator.onSwipeRight = onSwipeRight
        context.coordinator.setIsSwiping = { val in
            DispatchQueue.main.async { self.isSwiping = val }
        }
        context.coordinator.setSwipeProgress = { progress, direction in
            DispatchQueue.main.async {
                self.swipeProgress = progress
                self.swipeDirection = direction
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSwipeLeft: onSwipeLeft, onSwipeRight: onSwipeRight)
    }

    private static func findScrollView(from view: UIView) -> UIScrollView? {
        var current: UIView? = view
        while let v = current {
            if let sv = v as? UIScrollView { return sv }
            current = v.superview
        }
        return nil
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onSwipeLeft: () -> Void
        var onSwipeRight: () -> Void
        var setIsSwiping: ((Bool) -> Void)?
        var setSwipeProgress: ((CGFloat, CGFloat) -> Void)?
        weak var addedTo: UIScrollView?
        private var isHorizontalPan = false
        private let threshold: CGFloat = 50

        init(onSwipeLeft: @escaping () -> Void, onSwipeRight: @escaping () -> Void) {
            self.onSwipeLeft = onSwipeLeft
            self.onSwipeRight = onSwipeRight
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)

            switch gesture.state {
            case .changed:
                if !isHorizontalPan && abs(translation.x) > 15 && abs(translation.x) > abs(translation.y) * 1.5 {
                    isHorizontalPan = true
                    setIsSwiping?(true)
                    addedTo?.isScrollEnabled = false
                }
                if isHorizontalPan {
                    let progress = min(1, abs(translation.x) / threshold)
                    let direction: CGFloat = translation.x < 0 ? -1 : 1
                    setSwipeProgress?(progress, direction)
                }
            case .ended:
                if isHorizontalPan && abs(translation.x) > threshold {
                    if translation.x < 0 {
                        onSwipeLeft()
                    } else {
                        onSwipeRight()
                    }
                }
                if isHorizontalPan {
                    addedTo?.isScrollEnabled = true
                }
                isHorizontalPan = false
                setIsSwiping?(false)
                setSwipeProgress?(0, 0)
            case .cancelled:
                if isHorizontalPan {
                    addedTo?.isScrollEnabled = true
                }
                isHorizontalPan = false
                setIsSwiping?(false)
                setSwipeProgress?(0, 0)
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // ネストされた横スクロール（カテゴリチップ等）を優先
            if let otherScrollView = otherGestureRecognizer.view as? UIScrollView,
               otherScrollView != addedTo {
                return true
            }
            return false
        }
    }
}
#endif

// MARK: - FeedView

struct FeedView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Article.publishedAt, order: .reverse) private var allArticles: [Article]
    @State private var navigationPath = NavigationPath()
    @State private var viewModel: FeedViewModel?
    @State private var feedMode: FeedMode = .forYou
    @State private var selectedCategory: String? = nil
    @State private var hideAmount: CGFloat = 0
    @State private var cachedModeArticles: [Article] = []
    @State private var cachedCategoryCounts: [String: Int] = [:]
    @State private var sortedCategories: [String] = []
    @State private var gridOpacity: Double = 1
    @State private var isSwiping: Bool = false
    @State private var swipeProgress: CGFloat = 0
    @State private var swipeDirection: CGFloat = 0  // -1: left, 1: right
    @State private var currentScrollY: CGFloat = 0
    @State private var lastScrollY: CGFloat = 0

    let modelContainer: ModelContainer

    private let headerHeight: CGFloat = 90

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var columns: [GridItem] {
        #if os(macOS)
        return [GridItem(.adaptive(minimum: 280, maximum: 400), spacing: 16)]
        #else
        return horizontalSizeClass == .regular
            ? [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 12)]
            : [GridItem(.flexible())]
        #endif
    }

    // MARK: - データ

    private func updateCachedData() {
        let activeFeedURLs = viewModel?.activeSourceFeedURLs() ?? []

        var modeFiltered = allArticles.filter { article in
            guard activeFeedURLs.contains(article.sourceFeedURL) else { return false }
            switch feedMode {
            case .favorites:
                return article.isFavorite
            case .history:
                return article.isRead
            default:
                return true
            }
        }

        switch feedMode {
        case .forYou:
            modeFiltered.sort { a, b in
                if abs(a.relevanceScore - b.relevanceScore) > 0.01 {
                    return a.relevanceScore > b.relevanceScore
                }
                return (a.publishedAt ?? .distantPast) > (b.publishedAt ?? .distantPast)
            }
        case .latest, .favorites:
            break
        case .history:
            modeFiltered.sort { ($0.fetchedAt) > ($1.fetchedAt) }
        }

        cachedModeArticles = modeFiltered

        var counts: [String: Int] = [:]
        for article in modeFiltered {
            for cat in article.categories {
                counts[cat, default: 0] += 1
            }
        }
        cachedCategoryCounts = counts
        sortedCategories = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)

        if let cat = selectedCategory, counts[cat] == nil {
            selectedCategory = nil
        }
    }

    private var displayArticles: [Article] {
        guard let cat = selectedCategory else { return cachedModeArticles }
        return cachedModeArticles.filter { $0.categories.contains(cat) }
    }

    private var allCategoryOptions: [String?] {
        [nil] + sortedCategories.map { Optional($0) }
    }

    private var selectedCategoryIndex: Int {
        guard let cat = selectedCategory,
              let idx = sortedCategories.firstIndex(of: cat) else { return 0 }
        return idx + 1
    }

    // MARK: - スワイプでカテゴリ切り替え

    private func switchCategory(direction: Int) {
        let options = allCategoryOptions
        let current = selectedCategoryIndex
        let next = current + direction
        guard next >= 0, next < options.count else { return }

        withAnimation(.easeOut(duration: 0.12)) {
            gridOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            selectedCategory = options[next]
            scrollProxy?.scrollTo("scrollTop", anchor: .top)
            withAnimation(.easeIn(duration: 0.15)) {
                gridOpacity = 1
            }
        }
    }

    // MARK: - Hide on Scroll

    private var headerOffset: CGFloat {
        currentScrollY + hideAmount
    }

    private func handleScroll(_ newValue: CGFloat, _ oldValue: CGFloat) {
        let clampedNew = max(0, newValue)
        let clampedOld = max(0, oldValue)

        let delta = clampedNew - clampedOld
        guard abs(delta) > 0.5 else { return }

        if delta > 0 {
            hideAmount = max(-headerHeight, hideAmount - delta)
        } else {
            hideAmount = min(0, hideAmount - delta)
        }
    }

    private func handleScrollIdle() {
        withAnimation(.snappy(duration: 0.2)) {
            hideAmount = hideAmount < -headerHeight * 0.5 ? -headerHeight : 0
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $navigationPath) {
            mainContent
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
                .onChange(of: feedMode) {
                    hideAmount = 0
                    scrollProxy?.scrollTo("scrollTop", anchor: .top)
                    updateCachedData()
                }
                .onChange(of: selectedCategory) {
                    hideAmount = 0
                    scrollProxy?.scrollTo("scrollTop", anchor: .top)
                    updateCachedData()
                }
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
                .navigationDestination(for: Article.self) { article in
                    ArticleDetailView(article: article)
                }
        }
    }

    @State private var scrollProxy: ScrollViewProxy?

    private var mainContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ScrollViewSwipeHelper(
                        onSwipeLeft: { switchCategory(direction: 1) },
                        onSwipeRight: { switchCategory(direction: -1) },
                        isSwiping: $isSwiping,
                        swipeProgress: $swipeProgress,
                        swipeDirection: $swipeDirection
                    )
                    .frame(height: 0)
                    .id("scrollTop")

                    headerView
                        .zIndex(1)

                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(displayArticles, id: \.id) { article in
                            Button {
                                if !isSwiping {
                                    navigationPath.append(article)
                                }
                            } label: {
                                ArticleCardView(article: article, showScore: feedMode == .forYou)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                    .offset(x: isSwiping ? swipeDirection * swipeProgress * 30 : 0)
                    .opacity(isSwiping ? 1 - swipeProgress * 0.6 : gridOpacity)
                }
            }
            .onAppear { scrollProxy = proxy }
        }
        .contentMargins(.top, headerHeight, for: .scrollIndicators)
        .refreshable {
            await refreshAll()
        }
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, newValue in
            let oldValue = lastScrollY
            currentScrollY = newValue
            lastScrollY = newValue
            handleScroll(newValue, oldValue)
        }
        .onScrollPhaseChange { _, newPhase in
            if newPhase == .idle {
                handleScrollIdle()
            }
        }
    }

    private var headerView: some View {
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
        .offset(y: headerOffset)
        .opacity(headerHeight > 0 ? max(0, 1 + hideAmount / headerHeight) : 1)
    }

    private func refreshAll() async {
        await viewModel?.refresh()
        viewModel?.updateRelevanceScores()
        viewModel?.classifyInBackground()
        updateCachedData()
    }
}
