import SwiftUI
import SwiftData
import CoreData
import Combine

enum FeedMode: String, CaseIterable {
    case forYou = "おすすめ"
    case latest = "新着"
    case favorites = "お気に入り"
    case history = "閲覧履歴"

    /// UI 表示用の名前。お気に入り/履歴は集合のフィルタ、おすすめ/新着は同じ集合の並び順
    /// であることを「順」サフィックスで表す。rawValue は @AppStorage 互換のため固定。
    var displayName: String {
        switch self {
        case .forYou: return "おすすめ順"
        case .latest: return "新着順"
        case .favorites: return "お気に入り"
        case .history: return "閲覧履歴"
        }
    }

    var systemImage: String {
        switch self {
        case .forYou: return "sparkles"
        case .latest: return "bolt.badge.clock.fill"
        case .favorites: return "star.fill"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

enum SourceFilter: Equatable {
    case only(Source)
    case excluding([Source])

    var isExclude: Bool {
        if case .excluding = self { return true }
        return false
    }

    static func == (lhs: SourceFilter, rhs: SourceFilter) -> Bool {
        switch (lhs, rhs) {
        case (.only(let a), .only(let b)):
            return a.id == b.id
        case (.excluding(let a), .excluding(let b)):
            return Set(a.map(\.id)) == Set(b.map(\.id))
        default:
            return false
        }
    }
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

/// スクロール位置・ヘッダー隠し量を持つ。
/// FeedView の @State にすると毎フレームの scroll 更新で FeedView.body 全体が
/// 再評価されるため、@Observable 参照型に分離する。読むのは ScrollAwareHeader だけ。
@Observable
@MainActor
final class FeedScrollState {
    var currentScrollY: CGFloat = 0
    var lastScrollY: CGFloat = 0
    var hideAmount: CGFloat = 0
}

struct FeedView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \UserCategory.order) private var userCategoryModels: [UserCategory]
    @Query private var allSources: [Source]
    @State private var allArticles: [Article] = []
    @State private var navigationPath = NavigationPath()
    @State private var viewModel: FeedViewModel?
    @AppStorage("feedMode") private var feedMode: FeedMode = .forYou
    @State private var selectedCategory: String? = nil
    @State private var cachedModeArticles: [Article] = []
    @State private var cachedCategoryCounts: [String: Int] = [:]
    @State private var cachedDisplayArticles: [Article] = []
    @State private var sortedCategories: [String] = []
    @State private var gridOpacity: Double = 1
    @State private var isSwiping: Bool = false
    @State private var swipeProgress: CGFloat = 0
    @State private var swipeDirection: CGFloat = 0  // -1: left, 1: right
    /// スワイプ確定後、selectedCategory が実際に更新されるまでボーダープレビューを保持する候補。
    @State private var pendingPreview: CategoryChipPreview? = nil
    /// スクロール tracking 専用 state。@Observable 参照なので
    /// 読むビュー（ScrollAwareHeader）だけが invalidate される
    @State private var scrollState = FeedScrollState()
    @AppStorage("useCompactLayout") private var useCompactLayout = false
    @AppStorage("lastFeedRefreshedAt") private var lastFeedRefreshedAt: Double = 0
    @AppStorage("categoryFilterSortMode") private var filterSortModeRaw: String = CategoryFilterSortMode.count.rawValue
    @State private var hasNewSuggestions = false
    @State private var sourceFilter: SourceFilter? = nil
    @State private var sessionReadIDs: Set<UUID> = []
    @State private var lockedSortKeys: [UUID: Double] = [:]
    @State private var wasBackgrounded = false
    @State private var hasInitialRefreshed = false
    @State private var scoreBreakdownArticle: Article?
    @State private var pendingImpressions: [UUID: Int] = [:]
    @State private var impressionTimers: [UUID: Task<Void, Never>] = [:]
    @State private var sessionImpressed: Set<UUID> = []
    @Namespace private var zoomNamespace

    private let impressionDwellSeconds: Double = 1.0

    private let autoRefreshInterval: TimeInterval = 3600  // 1時間

    let modelContainer: ModelContainer

    private var headerHeight: CGFloat {
        #if os(iOS)
        sourceFilter != nil ? 95 : 55
        #else
        sourceFilter != nil ? 130 : 90
        #endif
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var hasActiveSource: Bool {
        allSources.contains(where: { $0.isActive })
    }

    private var activeFeedURLs: Set<URL> {
        Set(allSources.filter(\.isActive).map(\.feedURL))
    }

    private var shouldAutoRefresh: Bool {
        guard hasActiveSource else { return false }
        return Date().timeIntervalSince1970 - lastFeedRefreshedAt > autoRefreshInterval
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

    /// CloudKit同期や OG画像プリフェッチ完了時にフィードを再読み込みするトリガ
    private var reloadTriggerPublisher: AnyPublisher<Notification, Never> {
        Publishers.Merge(
            NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange),
            NotificationCenter.default.publisher(for: .articleEnrichmentCompleted)
        )
        .receive(on: DispatchQueue.main)
        .eraseToAnyPublisher()
    }

    private func updateCachedData() {
        let activeFeedURLs = viewModel?.activeSourceFeedURLs() ?? []

        var modeFiltered = allArticles.filter { article in
            guard activeFeedURLs.contains(article.sourceFeedURL) else { return false }
            switch sourceFilter {
            case .only(let s):
                if article.sourceFeedURL != s.feedURL { return false }
            case .excluding(let sources):
                if sources.contains(where: { $0.feedURL == article.sourceFeedURL }) { return false }
            case nil:
                break
            }
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
            // 表示中のスコアをロック: 初回表示時の値を記録、以降は固定して並びを安定化
            var lockedKeys = lockedSortKeys
            for article in modeFiltered where lockedKeys[article.id] == nil {
                lockedKeys[article.id] = article.relevanceScore
            }
            lockedSortKeys = lockedKeys

            let sessionReadIDs = self.sessionReadIDs
            func effectivelyRead(_ article: Article) -> Bool {
                article.isRead && !sessionReadIDs.contains(article.id)
            }
            modeFiltered.sort { a, b in
                let aRead = effectivelyRead(a)
                let bRead = effectivelyRead(b)
                if aRead != bRead { return !aRead }
                let aScore = lockedKeys[a.id] ?? a.relevanceScore
                let bScore = lockedKeys[b.id] ?? b.relevanceScore
                if abs(aScore - bScore) > 0.01 {
                    return aScore > bScore
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
        let mode = CategoryFilterSortMode(rawValue: filterSortModeRaw) ?? .count
        let hasOther = counts["その他"] != nil
        let nonOtherKeys = counts.keys.filter { $0 != "その他" }
        let baseOrder: [String]
        switch mode {
        case .count:
            baseOrder = nonOtherKeys.sorted { a, b in
                let ac = counts[a] ?? 0
                let bc = counts[b] ?? 0
                return ac != bc ? ac > bc : a < b
            }
        case .configured:
            // UserCategory の order に従う、ただし articles を持つもののみ
            baseOrder = cachedUserCategories.filter { counts[$0] != nil }
        }
        sortedCategories = baseOrder + (hasOther ? ["その他"] : [])

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

        // selectedCategory 更新までの 120ms、候補チップのボーダープレビューを保持し、
        // 切り替わり時にボーダー→塗りつぶしへ同フレームで遷移させる。
        pendingPreview = options[next].map { .named($0) } ?? .all

        withAnimation(.easeOut(duration: 0.12)) {
            gridOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            selectedCategory = options[next]
            pendingPreview = nil
            scrollProxy?.scrollTo("scrollTop", anchor: .top)
            withAnimation(.easeIn(duration: 0.15)) {
                gridOpacity = 1
            }
        }
    }

    // MARK: - Hide on Scroll

    private func handleScroll(_ newValue: CGFloat, _ oldValue: CGFloat) {
        // Pull-to-refresh中（上に引っ張り）はヘッダーを表示
        if newValue < 0 {
            if scrollState.hideAmount < 0 {
                withAnimation(.snappy(duration: 0.2)) {
                    scrollState.hideAmount = 0
                }
            }
            return
        }

        let clampedNew = max(0, newValue)
        let clampedOld = max(0, oldValue)

        let delta = clampedNew - clampedOld
        guard abs(delta) > 0.5 else { return }

        if delta > 0 {
            scrollState.hideAmount = max(-headerHeight, scrollState.hideAmount - delta)
        } else {
            scrollState.hideAmount = min(0, scrollState.hideAmount - delta)
        }
    }

    private func handleScrollIdle() {
        withAnimation(.snappy(duration: 0.2)) {
            scrollState.hideAmount = scrollState.hideAmount < -headerHeight * 0.5 ? -headerHeight : 0
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
                    flushImpressions()
                    scrollState.hideAmount = 0
                    scrollProxy?.scrollTo("scrollTop", anchor: .top)
                    withAnimation(.easeInOut(duration: 0.35)) {
                        updateCachedData()
                    }
                }
                .onChange(of: selectedCategory) {
                    flushImpressions()
                    scrollState.hideAmount = 0
                    scrollProxy?.scrollTo("scrollTop", anchor: .top)
                    updateCachedData()
                }
                .onChange(of: sourceFilter) {
                    flushImpressions()
                    scrollState.hideAmount = 0
                    scrollProxy?.scrollTo("scrollTop", anchor: .top)
                    updateCachedData()
                }
                .onChange(of: isSwiping) {
                    if isSwiping, scrollState.hideAmount < 0 {
                        withAnimation(.snappy(duration: 0.2)) {
                            scrollState.hideAmount = 0
                        }
                    }
                }
                .onChange(of: filterSortModeRaw) {
                    updateCachedData()
                }
                .navigationTitle("Seekthea")
                #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    #if !os(iOS)
                    ToolbarItem(placement: .automatic) {
                        Button {
                            sessionReadIDs.removeAll()
                            lockedSortKeys.removeAll()
                            Task { await refreshAll() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(viewModel?.isLoading ?? false)
                    }
                    #endif
                    #if !os(iOS)
                    // macOS / visionOS は標準 toolbar を使う (iOS は浮遊バー)
                    ToolbarItem(placement: .automatic) {
                        Menu {
                            feedNavigationMenuItems(
                                modelContainer: modelContainer,
                                hasNewSuggestions: hasNewSuggestions
                            )
                        } label: {
                            Image(systemName: "ellipsis")
                                .overlay(alignment: .topTrailing) {
                                    if hasNewSuggestions {
                                        Circle()
                                            .fill(.red)
                                            .frame(width: 8, height: 8)
                                            .offset(x: 4, y: -4)
                                    }
                                }
                        }
                    }
                    #endif
                }
                .task {
                    if viewModel == nil {
                        viewModel = FeedViewModel(modelContainer: modelContainer)
                    }
                    if !hasInitialRefreshed {
                        hasInitialRefreshed = true
                        await refreshAll()
                    }
                }
                .onAppear {
                    if viewModel != nil {
                        reloadArticles()
                        updateCachedData()
                    }
                    hasNewSuggestions = DiscoveryManager.shared.hasUncheckedSuggestions(in: modelContext)
                }
                .onReceive(NotificationCenter.default.publisher(for: .onboardingCompleted)) { _ in
                    Task { await refreshAll() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .discoveryCompleted)) { _ in
                    hasNewSuggestions = DiscoveryManager.shared.hasUncheckedSuggestions(in: modelContext)
                }
                .onReceive(reloadTriggerPublisher) { _ in
                    reloadArticles()
                    updateCachedData()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background {
                        wasBackgrounded = true
                    }
                    if newPhase == .active {
                        // バックグラウンド復帰時はソート順を再ランキングするためロック解除
                        if wasBackgrounded {
                            wasBackgrounded = false
                            lockedSortKeys.removeAll()
                            sessionReadIDs.removeAll()
                        }
                        reloadArticles()
                        updateCachedData()
                        if shouldAutoRefresh {
                            Task { await refreshAll() }
                        }
                    } else {
                        flushImpressions()
                    }
                }
                .onChange(of: activeFeedURLs) {
                    clearStaleSourceFilter()
                    // 即時にDB状態を表示へ反映（Source削除時の cascade 結果やフィルタ更新）。
                    // RSS再取得は重いので別タスクで非同期に。
                    reloadArticles()
                    updateCachedData()
                    Task { await refreshAll() }
                }
                .onChange(of: hasActiveSource) { _, newValue in
                    if !newValue {
                        viewModel?.cancelClassification()
                    }
                }
                .navigationDestination(for: Article.self) { article in
                    let detail = ArticleDetailView(article: article)
                    #if os(macOS)
                    detail
                    #else
                    detail.navigationTransition(.zoom(sourceID: article.id, in: zoomNamespace))
                    #endif
                }
                .sheet(item: $scoreBreakdownArticle) { article in
                    ScoreBreakdownView(article: article, modelContainer: modelContainer)
                }
                .overlay(alignment: .bottom) {
                    let feedStatus = viewModel?.statusMessage
                    let discoveryStatus = DiscoveryManager.shared.statusMessage
                    let syncStatus = CloudSyncObserver.shared.statusMessage
                    #if os(iOS)
                    FeedFloatingFooter(
                        scrollState: scrollState,
                        feedStatus: feedStatus,
                        discoveryStatus: discoveryStatus,
                        syncStatus: syncStatus,
                        hasNewSuggestions: hasNewSuggestions,
                        modelContainer: modelContainer,
                        useCompactLayout: $useCompactLayout,
                        feedMode: $feedMode
                    )
                    #else
                    if feedStatus != nil || discoveryStatus != nil || syncStatus != nil {
                        VStack(spacing: 4) {
                            if let status = feedStatus { StatusProgressCapsule(text: status) }
                            if let status = discoveryStatus { StatusProgressCapsule(text: status) }
                            if let status = syncStatus { StatusProgressCapsule(text: status) }
                        }
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    #endif
                }
                .animation(.easeInOut(duration: 0.3), value: viewModel?.statusMessage)
                .animation(.easeInOut(duration: 0.3), value: DiscoveryManager.shared.statusMessage)
                .animation(.easeInOut(duration: 0.3), value: CloudSyncObserver.shared.statusMessage)
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
                                    openArticle(article)
                                }
                            } label: {
                                if useCompactLayout {
                                    CompactArticleCardView(article: article, displayImageURL: article.displayImageURL, showScore: feedMode == .forYou)
                                } else {
                                    ArticleCardView(article: article, displayImageURL: article.displayImageURL, showScore: feedMode == .forYou)
                                }
                            }
                            .buttonStyle(.plain)
                            .matchedTransitionSource(id: article.id, in: zoomNamespace)
                            .contextMenu { contextMenuItems(for: article) }
                            .onAppear { startImpressionTimer(for: article) }
                            .onDisappear { cancelImpressionTimer(for: article.id) }
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
                let oldValue = scrollState.lastScrollY
                scrollState.currentScrollY = newValue
                scrollState.lastScrollY = newValue
                handleScroll(newValue, oldValue)
            }
            .onScrollPhaseChange { _, newPhase in
                if newPhase == .idle {
                    handleScrollIdle()
                    flushImpressions()
                }
            }
            .refreshable {
                sessionReadIDs.removeAll()
                lockedSortKeys.removeAll()
                await refreshAll()
            }
        }
        .contentMargins(.top, headerHeight, for: .scrollIndicators)
    }

    private var headerView: some View {
        ScrollAwareHeader(
            scrollState: scrollState,
            feedMode: $feedMode,
            selectedCategory: $selectedCategory,
            totalCount: cachedModeArticles.count,
            categoryCounts: cachedCategoryCounts,
            categoryOrder: sortedCategories,
            categoryPreview: categoryPreview,
            categoryPreviewProgress: categoryPreviewProgress,
            headerHeight: headerHeight,
            sourceFilter: sourceFilter,
            excludeSummary: excludeSummary,
            onClearSourceFilter: { changeSourceFilter(to: nil) }
        )
    }

    /// スワイプ中／確定後切り替わるまでの間ハイライトする候補チップ。
    private var categoryPreview: CategoryChipPreview? {
        if isSwiping && swipeProgress > 0 {
            // swipeDirection -1 (visual left) → 次のカテゴリ (+1)、+1 (visual right) → 前のカテゴリ (-1)
            let dir = swipeDirection < 0 ? 1 : -1
            let target = selectedCategoryIndex + dir
            guard target >= 0, target < allCategoryOptions.count else { return nil }
            return allCategoryOptions[target].map { .named($0) } ?? .all
        }
        return pendingPreview
    }

    /// プレビューボーダーの濃さ。スワイプ中は progress、確定〜selectedCategory 更新までは 1。
    private var categoryPreviewProgress: CGFloat {
        if isSwiping && swipeProgress > 0 { return swipeProgress }
        return pendingPreview != nil ? 1 : 0
    }

    private func openArticle(_ article: Article) {
        sessionReadIDs.insert(article.id)
        cancelImpressionTimer(for: article.id)
        pendingImpressions[article.id] = nil
        navigationPath.append(article)
    }

    // MARK: - Impression tracking

    private func startImpressionTimer(for article: Article) {
        let id = article.id
        guard !article.isRead, !sessionImpressed.contains(id) else { return }
        impressionTimers[id]?.cancel()
        impressionTimers[id] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(impressionDwellSeconds))
            guard !Task.isCancelled else { return }
            sessionImpressed.insert(id)
            pendingImpressions[id, default: 0] += 1
            impressionTimers[id] = nil
        }
    }

    private func cancelImpressionTimer(for id: UUID) {
        impressionTimers[id]?.cancel()
        impressionTimers[id] = nil
    }

    private func flushImpressions() {
        guard !pendingImpressions.isEmpty else { return }
        let snapshot = pendingImpressions
        pendingImpressions.removeAll()
        for (id, delta) in snapshot {
            if let article = allArticles.first(where: { $0.id == id }) {
                article.impressionCount += delta
            }
        }
        try? modelContext.save()
    }

    @ViewBuilder
    private func contextMenuItems(for article: Article) -> some View {
        Button {
            openArticle(article)
        } label: {
            Label("開く", systemImage: "arrow.up.right.square")
        }

        if let source = article.source {
            if case .only(let s) = sourceFilter, s.id == source.id {
                Button {
                    changeSourceFilter(to: nil)
                } label: {
                    Label("フィルタを解除", systemImage: "xmark.circle")
                }
            } else if case .excluding(let sources) = sourceFilter,
                      sources.contains(where: { $0.id == source.id }) {
                Button {
                    let remaining = sources.filter { $0.id != source.id }
                    changeSourceFilter(to: remaining.isEmpty ? nil : .excluding(remaining))
                } label: {
                    Label("\(source.name) の除外を解除", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    changeSourceFilter(to: .only(source))
                } label: {
                    Label("\(source.name) だけ表示", systemImage: "line.3.horizontal.decrease.circle")
                }
                if case .excluding(let sources) = sourceFilter {
                    Button {
                        changeSourceFilter(to: .excluding(sources + [source]))
                    } label: {
                        Label("\(source.name) も除外", systemImage: "eye.slash")
                    }
                } else {
                    Button {
                        changeSourceFilter(to: .excluding([source]))
                    } label: {
                        Label("\(source.name) を除外", systemImage: "eye.slash")
                    }
                }
            }
        }

        Button {
            article.isFavorite.toggle()
            try? modelContext.save()
        } label: {
            Label(
                article.isFavorite ? "お気に入りから外す" : "お気に入りに追加",
                systemImage: article.isFavorite ? "star.slash" : "star"
            )
        }

        ShareLink(item: article.articleURL) {
            Label("共有", systemImage: "square.and.arrow.up")
        }

        Button {
            scoreBreakdownArticle = article
        } label: {
            Label("スコアの内訳", systemImage: "chart.bar.doc.horizontal")
        }
    }

    private func changeSourceFilter(to newFilter: SourceFilter?) {
        guard sourceFilter != newFilter else { return }
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        withAnimation(.easeOut(duration: 0.12)) {
            gridOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            sourceFilter = newFilter
            withAnimation(.easeIn(duration: 0.15)) {
                gridOpacity = 1
            }
        }
    }

    private func clearStaleSourceFilter() {
        switch sourceFilter {
        case .only(let s):
            if !allSources.contains(where: { $0.id == s.id }) {
                sourceFilter = nil
            }
        case .excluding(let sources):
            let alive = sources.filter { s in allSources.contains(where: { $0.id == s.id }) }
            if alive.isEmpty {
                sourceFilter = nil
            } else if alive.count != sources.count {
                sourceFilter = .excluding(alive)
            }
        case nil:
            break
        }
    }

    private func excludeSummary(_ sources: [Source]) -> String {
        if sources.count <= 2 {
            return sources.map(\.name).joined(separator: ", ")
        }
        return "\(sources[0].name) +\(sources.count - 1)"
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
        // CloudKit同期で届いた重複もここで整理
        await DataDeduplicator.run(in: modelContext) { [weak viewModel] message in
            viewModel?.statusMessage = message
        }
        lastFeedRefreshedAt = Date().timeIntervalSince1970
        reloadArticles()
        updateCachedData()
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
                hasNewSuggestions = DiscoveryManager.shared.hasUncheckedSuggestions(in: modelContext)
            }
        )
    }
}

// MARK: - ScrollAwareHeader

/// FeedView の header を別struct に切り出し、scrollState を直接読むことで
/// scroll 更新時に FeedView.body を invalidate しないようにする。
private struct ScrollAwareHeader: View {
    let scrollState: FeedScrollState
    @Binding var feedMode: FeedMode
    @Binding var selectedCategory: String?
    let totalCount: Int
    let categoryCounts: [String: Int]
    let categoryOrder: [String]
    let categoryPreview: CategoryChipPreview?
    let categoryPreviewProgress: CGFloat
    let headerHeight: CGFloat
    let sourceFilter: SourceFilter?
    let excludeSummary: ([Source]) -> String
    let onClearSourceFilter: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            #if !os(iOS)
            Picker("モード", selection: $feedMode) {
                ForEach(FeedMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 4)
            #endif

            CategoryFilterView(
                selectedCategory: $selectedCategory,
                totalCount: totalCount,
                categoryCounts: categoryCounts,
                categoryOrder: categoryOrder,
                preview: categoryPreview,
                previewProgress: categoryPreviewProgress
            )
            .padding(.vertical, 6)

            if let filter = sourceFilter {
                sourceFilterChip(filter)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }
        }
        .frame(height: headerHeight)
        .background(alignment: .top) {
            let extraHeight: CGFloat = scrollState.currentScrollY < 0 ? 0 : 500
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
        .offset(y: max(0, scrollState.currentScrollY) + scrollState.hideAmount)
        .opacity(headerHeight > 0 ? max(0, 1 + scrollState.hideAmount / headerHeight) : 1)
    }

    @ViewBuilder
    private func sourceFilterChip(_ filter: SourceFilter) -> some View {
        HStack {
            Button {
                onClearSourceFilter()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: filter.isExclude ? "eye.slash" : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(Color.accentColor)
                    switch filter {
                    case .only(let s):
                        Text(s.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    case .excluding(let sources):
                        Text("除外: ")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(excludeSummary(sources))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }
}

// MARK: - StatusStackLayout

/// ステータス capsule 複数 + action bar を底辺に配置する Custom Layout。
/// 最後の subview を action bar として扱い、それ以外を status capsule として積み上げる。
/// action bar は最下段に専有させ、status capsule はその上にセンター配置で順次積む。
/// action bar がスクロールで半分以上隠れた時のみ、status は底辺まで降りてくる。
struct StatusStackLayout: Layout {
    /// action bar の下方向オフセット（スクロールで隠す時用、0 で通常位置）
    var actionBarOffsetY: CGFloat = 0
    var verticalSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.reduce(0, +)
        return CGSize(width: width, height: max(height, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let actionBar = subviews.last!
        let actionSize = actionBar.sizeThatFits(.unspecified)
        let actionX = bounds.maxX - actionSize.width
        let actionY = bounds.maxY - actionSize.height + actionBarOffsetY

        actionBar.place(
            at: CGPoint(x: actionX, y: actionY),
            anchor: .topLeading,
            proposal: ProposedViewSize(actionSize)
        )

        let isActionEffectivelyVisible = actionBarOffsetY < actionSize.height * 0.5
        let statuses = subviews.dropLast()
        var currentBottom = isActionEffectivelyVisible
            ? actionY - verticalSpacing
            : bounds.maxY

        for status in statuses.reversed() {
            let statusSize = status.sizeThatFits(.unspecified)
            let statusY = currentBottom - statusSize.height

            var statusCenterX = bounds.midX
            statusCenterX = max(statusCenterX, bounds.minX + statusSize.width / 2)

            let statusX = statusCenterX - statusSize.width / 2
            status.place(
                at: CGPoint(x: statusX, y: statusY),
                anchor: .topLeading,
                proposal: ProposedViewSize(statusSize)
            )
            currentBottom = statusY - verticalSpacing
        }
    }
}

// MARK: - FeedFloatingFooter

#if os(iOS)
/// ステータス capsule と浮遊アクションバーをまとめて底辺に表示する overlay 用 View。
/// scrollState を直接読むことで、スクロール中に FeedView.body の再評価を避ける。
/// glassEffect が iOS 限定のため、構造体ごと iOS 専用にしている。
private struct FeedFloatingFooter: View {
    let scrollState: FeedScrollState
    let feedStatus: String?
    let discoveryStatus: String?
    let syncStatus: String?
    let hasNewSuggestions: Bool
    let modelContainer: ModelContainer
    @Binding var useCompactLayout: Bool
    @Binding var feedMode: FeedMode

    /// スクロールで隠れる量からアクションバーの不透明度を算出。
    /// fadeDistance スライドで完全に透明になる。iOS のヘッダー高 (~55) より短く
    /// 設定しないと、最大 hide 時点でも完全には消えない。
    private var actionBarOpacity: Double {
        let hidden = max(0, -scrollState.hideAmount)
        let fadeDistance: CGFloat = 45
        return max(0, 1 - Double(hidden / fadeDistance))
    }

    var body: some View {
        StatusStackLayout(actionBarOffsetY: max(0, -scrollState.hideAmount)) {
            if let s = feedStatus { StatusProgressCapsule(text: s) }
            if let s = discoveryStatus { StatusProgressCapsule(text: s) }
            if let s = syncStatus { StatusProgressCapsule(text: s) }
            HStack(spacing: 0) {
                FeedModePill(feedMode: $feedMode)
                Divider()
                    .frame(height: 22)
                FloatingActionBar(
                    modelContainer: modelContainer,
                    hasNewSuggestions: hasNewSuggestions,
                    useCompactLayout: $useCompactLayout
                )
            }
            .glassEffect(.regular, in: Capsule())
            .shadow(radius: 4)
            .opacity(actionBarOpacity)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        // Safari のように SafeArea の中（home indicator 領域）まで入り込ませる
        .ignoresSafeArea(.container, edges: .bottom)
    }

}
#endif

/// FeedView の浮遊メニュー (iOS) と toolbar メニュー (macOS / visionOS) で共通の遷移項目。
/// iOS 側は先頭に「コンパクト切替」を別途追加する。
@ViewBuilder
private func feedNavigationMenuItems(modelContainer: ModelContainer, hasNewSuggestions: Bool) -> some View {
    NavigationLink {
        SourcesListView(modelContainer: modelContainer)
    } label: {
        Label("ソース管理", systemImage: "plus.rectangle.on.rectangle")
    }
    NavigationLink {
        DiscoveryView(modelContainer: modelContainer)
    } label: {
        Label(
            hasNewSuggestions ? "発見（新着あり）" : "発見",
            systemImage: "sparkle.magnifyingglass"
        )
    }
    NavigationLink {
        CategorySettingsView()
    } label: {
        Label("カテゴリ管理", systemImage: "square.grid.2x2")
    }
    Divider()
    NavigationLink {
        SettingsView()
    } label: {
        Label("設定", systemImage: "gear")
    }
}

/// 浮遊するステータス capsule (進行中インジケータ + テキスト)。
/// FeedFloatingFooter (iOS) と mainContent の非iOSフォールバック両方で使う。
private struct StatusProgressCapsule: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                #if !os(macOS)
                .controlSize(.small)
                #endif
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(radius: 4)
    }
}

// MARK: - FloatingActionBar

/// 右下に浮遊表示する丸ボタン。Menu で コンパクト切替 / 発見 / ソース管理 / 設定 にアクセス。
private struct FloatingActionBar: View {
    let modelContainer: ModelContainer
    let hasNewSuggestions: Bool
    @Binding var useCompactLayout: Bool

    var body: some View {
        Menu {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    useCompactLayout.toggle()
                }
            } label: {
                Label(
                    useCompactLayout ? "大きいカード" : "コンパクト",
                    systemImage: useCompactLayout ? "rectangle.grid.1x2" : "rectangle.grid.2x2"
                )
            }
            Divider()
            feedNavigationMenuItems(
                modelContainer: modelContainer,
                hasNewSuggestions: hasNewSuggestions
            )
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if hasNewSuggestions {
                        Circle()
                            .fill(.red)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                            .offset(x: 4, y: 6)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

// MARK: - FeedModePill

/// 浮遊バーに置く現モードピル。タップで4モードのメニューが開く。
private struct FeedModePill: View {
    @Binding var feedMode: FeedMode

    var body: some View {
        Menu {
            Picker(selection: $feedMode) {
                ForEach(FeedMode.allCases, id: \.self) { mode in
                    Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
                }
            } label: {
                Text("モード")
            }
        } label: {
            Image(systemName: feedMode.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
                .accessibilityLabel("モード: \(feedMode.displayName)")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }
}
