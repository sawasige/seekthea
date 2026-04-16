import SwiftUI
import SwiftData
import CoreData
import Combine

enum FeedMode: String, CaseIterable {
    case forYou = "おすすめ"
    case latest = "新着"
    case favorites = "お気に入り"
    case history = "閲覧履歴"
}

// MARK: - UIKit横スワイプ検知

#if os(iOS)

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
    var canSwipeLeft: Bool
    var canSwipeRight: Bool

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
        context.coordinator.canSwipeLeft = canSwipeLeft
        context.coordinator.canSwipeRight = canSwipeRight
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
        var canSwipeLeft = true
        var canSwipeRight = true
        weak var addedTo: UIScrollView?
        private var isHorizontalPan = false
        private var isPastThreshold = false
        private var lastDirection: CGFloat = 0
        private var edgeHapticFired = false
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
                    // 縦スクロール中は横スワイプを開始しない
                    if let sv = addedTo, sv.isDragging || sv.isDecelerating {
                        break
                    }
                    isHorizontalPan = true
                    setIsSwiping?(true)
                    addedTo?.isScrollEnabled = false
                }
                if isHorizontalPan {
                    let direction: CGFloat = translation.x < 0 ? -1 : 1
                    let goingLeft = direction < 0
                    let currentlyBlocked = (goingLeft && !canSwipeLeft) || (!goingLeft && !canSwipeRight)

                    // 方向が変わったら各状態をリセット
                    if direction != lastDirection {
                        isPastThreshold = false
                        edgeHapticFired = false
                        lastDirection = direction
                    }

                    if currentlyBlocked {
                        let rubberBand = min(0.3, abs(translation.x) / threshold * 0.3)
                        setSwipeProgress?(rubberBand, direction)
                        if !edgeHapticFired && abs(translation.x) > threshold {
                            edgeHapticFired = true
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        }
                    } else {
                        let progress = min(1, abs(translation.x) / threshold)
                        setSwipeProgress?(progress, direction)

                        let past = abs(translation.x) > threshold
                        if past && !isPastThreshold {
                            isPastThreshold = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } else if !past && isPastThreshold {
                            isPastThreshold = false
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                        }
                    }
                }
            case .ended:
                if isHorizontalPan && abs(translation.x) > threshold {
                    let goingLeft = translation.x < 0
                    let blocked = (goingLeft && !canSwipeLeft) || (!goingLeft && !canSwipeRight)
                    if !blocked {
                        if goingLeft {
                            onSwipeLeft()
                        } else {
                            onSwipeRight()
                        }
                    }
                }
                if isHorizontalPan {
                    addedTo?.isScrollEnabled = true
                }
                isHorizontalPan = false
                isPastThreshold = false
                edgeHapticFired = false
                lastDirection = 0
                setIsSwiping?(false)
                setSwipeProgress?(0, 0)
            case .cancelled:
                if isHorizontalPan {
                    addedTo?.isScrollEnabled = true
                }
                isHorizontalPan = false
                isPastThreshold = false
                edgeHapticFired = false
                lastDirection = 0
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
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \UserCategory.order) private var userCategoryModels: [UserCategory]
    @Query private var allSources: [Source]
    @State private var allArticles: [Article] = []
    @State private var navigationPath = NavigationPath()
    @State private var viewModel: FeedViewModel?
    @State private var feedMode: FeedMode = .forYou
    @State private var selectedCategory: String? = nil
    @State private var hideAmount: CGFloat = 0
    @State private var cachedModeArticles: [Article] = []
    @State private var cachedCategoryCounts: [String: Int] = [:]
    @State private var cachedDisplayArticles: [Article] = []
    @State private var sortedCategories: [String] = []
    @State private var gridOpacity: Double = 1
    @State private var isSwiping: Bool = false
    @State private var swipeProgress: CGFloat = 0
    @State private var swipeDirection: CGFloat = 0  // -1: left, 1: right
    @State private var currentScrollY: CGFloat = 0
    @State private var lastScrollY: CGFloat = 0
    @AppStorage("useCompactLayout") private var useCompactLayout = false

    let modelContainer: ModelContainer

    private let headerHeight: CGFloat = 90

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var hasActiveSource: Bool {
        allSources.contains(where: { $0.isActive })
    }

    private var emptyFeedTitle: String {
        if allSources.isEmpty { return "ソースがありません" }
        if !hasActiveSource { return "有効なソースがありません" }
        return "記事がありません"
    }

    private var emptyFeedIcon: String {
        if allSources.isEmpty { return "tray" }
        if !hasActiveSource { return "pause.circle" }
        return "newspaper"
    }

    private var emptyFeedHint: String {
        if allSources.isEmpty {
            return "設定からソースを追加してください"
        }
        if !hasActiveSource {
            return "ソース管理でソースをオンにしてください"
        }
        #if os(macOS)
        return "更新ボタンを押してください"
        #else
        return "下に引いて更新"
        #endif
    }

    private var columns: [GridItem] {
        #if os(macOS)
        return [GridItem(.adaptive(minimum: 280, maximum: 400), spacing: 16)]
        #else
        if useCompactLayout {
            let isPhone = UIDevice.current.userInterfaceIdiom == .phone
            if isPhone {
                let count = verticalSizeClass == .compact ? 3 : 2
                return Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
            } else {
                return [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 8)]
            }
        }
        return horizontalSizeClass == .regular
            ? [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 12)]
            : [GridItem(.flexible())]
        #endif
    }

    // MARK: - データ

    private func reloadArticles() {
        allArticles = viewModel?.fetchArticles() ?? []
    }

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

        let knownCategories = Set(cachedUserCategories)
        var counts: [String: Int] = [:]
        for article in modeFiltered {
            for cat in article.categories {
                let displayCat = knownCategories.contains(cat) ? cat : "その他"
                counts[displayCat, default: 0] += 1
            }
        }
        cachedCategoryCounts = counts
        sortedCategories = counts.sorted {
            if $0.key == "その他" { return false }
            if $1.key == "その他" { return true }
            return $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }.map(\.key)

        if let cat = selectedCategory, counts[cat] == nil {
            selectedCategory = nil
        }

        // displayArticlesをキャッシュ
        if let cat = selectedCategory {
            if cat == "その他" {
                cachedDisplayArticles = modeFiltered.filter { article in
                    article.categories.contains { !knownCategories.contains($0) }
                }
            } else {
                cachedDisplayArticles = modeFiltered.filter { $0.categories.contains(cat) }
            }
        } else {
            cachedDisplayArticles = modeFiltered
        }
    }

    private var cachedUserCategories: [String] {
        let names = userCategoryModels.map(\.name)
        return names.isEmpty ? UserCategory.defaults : names
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
        max(0, currentScrollY) + hideAmount
    }

    private func handleScroll(_ newValue: CGFloat, _ oldValue: CGFloat) {
        // Pull-to-refresh中（上に引っ張り）はヘッダーを表示
        if newValue < 0 {
            if hideAmount < 0 {
                withAnimation(.snappy(duration: 0.2)) {
                    hideAmount = 0
                }
            }
            return
        }

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
                    if cachedDisplayArticles.isEmpty {
                        if viewModel == nil || viewModel?.isLoading == true {
                            ProgressView("読み込み中...")
                        } else {
                            ContentUnavailableView(
                                emptyFeedTitle,
                                systemImage: emptyFeedIcon,
                                description: Text(emptyFeedHint)
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
                .onChange(of: isSwiping) {
                    if isSwiping, hideAmount < 0 {
                        withAnimation(.snappy(duration: 0.2)) {
                            hideAmount = 0
                        }
                    }
                }
                .navigationTitle("Seekthea")
                #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    #if os(macOS)
                    ToolbarItem(placement: .automatic) {
                        Button {
                            Task { await refreshAll() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(viewModel?.isLoading ?? false)
                    }
                    #endif
                    #if !os(macOS)
                    ToolbarItem(placement: .automatic) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                useCompactLayout.toggle()
                            }
                        } label: {
                            Image(systemName: useCompactLayout ? "rectangle.grid.1x2" : "rectangle.grid.2x2")
                        }
                    }
                    #endif
                    ToolbarItem(placement: .automatic) {
                        NavigationLink {
                            SettingsView()
                        } label: {
                            Image(systemName: "gear")
                        }
                    }
                }
                .task {
                    if viewModel == nil {
                        viewModel = FeedViewModel(modelContainer: modelContainer)
                    }
                    await refreshAll()
                }
                .onAppear {
                    if viewModel != nil {
                        reloadArticles()
                        updateCachedData()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .onboardingCompleted)) { _ in
                    Task { await refreshAll() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange).receive(on: DispatchQueue.main)) { _ in
                    reloadArticles()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        reloadArticles()
                        updateCachedData()
                    }
                }
                .onChange(of: allSources.count) {
                    Task { await refreshAll() }
                }
                .onChange(of: hasActiveSource) { _, newValue in
                    if !newValue {
                        viewModel?.cancelClassification()
                    }
                }
                .navigationDestination(for: Article.self) { article in
                    ArticleDetailView(article: article)
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
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .shadow(radius: 4)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: viewModel?.statusMessage)
        }
    }

    @State private var scrollProxy: ScrollViewProxy?

    private var mainContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    #if os(iOS)
                    ScrollViewSwipeHelper(
                        onSwipeLeft: { switchCategory(direction: 1) },
                        onSwipeRight: { switchCategory(direction: -1) },
                        isSwiping: $isSwiping,
                        swipeProgress: $swipeProgress,
                        swipeDirection: $swipeDirection,
                        canSwipeLeft: selectedCategoryIndex < allCategoryOptions.count - 1,
                        canSwipeRight: selectedCategoryIndex > 0
                    )
                    .frame(height: 0)
                    .id("scrollTop")
                    #else
                    Color.clear
                        .frame(height: 0)
                        .id("scrollTop")
                    #endif

                    headerView
                        .zIndex(1)

                    LazyVGrid(columns: columns, spacing: useCompactLayout ? 8 : 16) {
                        ForEach(cachedDisplayArticles, id: \.id) { article in
                            Button {
                                if !isSwiping {
                                    navigationPath.append(article)
                                }
                            } label: {
                                if useCompactLayout {
                                    CompactArticleCardView(article: article, showScore: feedMode == .forYou)
                                } else {
                                    ArticleCardView(article: article, showScore: feedMode == .forYou)
                                }
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
            .refreshable {
                await refreshAll()
            }
        }
        .contentMargins(.top, headerHeight, for: .scrollIndicators)
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

            CategoryFilterView(selectedCategory: $selectedCategory, totalCount: cachedModeArticles.count, categoryCounts: cachedCategoryCounts, categoryOrder: sortedCategories)
                .padding(.vertical, 6)
        }
        .frame(height: headerHeight)
        .background(alignment: .top) {
            let extraHeight: CGFloat = currentScrollY < 0 ? 0 : 500
            #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
                .frame(height: headerHeight + extraHeight)
                .offset(y: -extraHeight)
            #else
            Color(uiColor: .systemBackground)
                .frame(height: headerHeight + extraHeight)
                .offset(y: -extraHeight)
            #endif
        }
        .offset(y: headerOffset)
        .opacity(headerHeight > 0 ? max(0, 1 + hideAmount / headerHeight) : 1)
    }

    private func refreshAll() async {
        if !hasActiveSource {
            viewModel?.cancelClassification()
            reloadArticles()
            updateCachedData()
            return
        }
        guard viewModel?.isLoading != true else { return }
        await viewModel?.refresh()
        reloadArticles()
        updateCachedData()
        if viewModel?.isClassifying == true { return }
        viewModel?.classifyInBackground(
            onArticleClassified: { [self] in
                reloadArticles()
                updateCachedData()
            },
            onComplete: { [self] in
                viewModel?.statusMessage = "スコアを計算中..."
                viewModel?.updateRelevanceScores()
                viewModel?.statusMessage = nil
                reloadArticles()
                updateCachedData()
            }
        )
    }
}
