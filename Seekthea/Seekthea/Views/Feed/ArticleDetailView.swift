import SwiftUI
import SwiftData
import WebKit
#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - ArticleDetailContainer

/// 記事詳細のラッパー。前の/次の記事カードからの遷移を受けて、
/// `currentArticle` を差し替える。差し替え時には `.id(article.id)` により
/// `ArticleDetailView` の @State が完全リセットされ、新しい記事として読み込み直される。
///
/// 前後の記事は `ArticleNavigationContext.shared` のスナップショットから解決する。
struct ArticleDetailContainer: View {
    let initialArticle: Article
    /// 戻る時の zoom transition の source 解決用 namespace。
    /// FeedView のカードにも同じ namespace で `matchedTransitionSource` が貼られている。
    let zoomNamespace: Namespace.ID?
    @State private var currentArticle: Article

    init(initialArticle: Article, zoomNamespace: Namespace.ID? = nil) {
        self.initialArticle = initialArticle
        self.zoomNamespace = zoomNamespace
        self._currentArticle = State(initialValue: initialArticle)
    }

    var body: some View {
        let neighbors = ArticleNavigationContext.shared.neighbors(of: currentArticle)
        ArticleDetailView(
            article: currentArticle,
            previousArticle: neighbors.previous,
            nextArticle: neighbors.next,
            onNavigatePrev: {
                if let p = neighbors.previous {
                    // セッション保護に登録（フィードに戻った時にこの記事も
                    // 元の位置に留まるように。FeedView の openArticle と同等処理）。
                    ArticleNavigationContext.shared.markVisited(p.id)
                    // SwiftUI の更新サイクル内で .id() による identity 変更を起こすと
                    // 描画ツリーの torn down と onTap 元の view 破棄が同期して
                    // クラッシュすることがある。次の runloop に逃がす。
                    Task { @MainActor in currentArticle = p }
                }
            },
            onNavigateNext: {
                if let n = neighbors.next {
                    ArticleNavigationContext.shared.markVisited(n.id)
                    Task { @MainActor in currentArticle = n }
                }
            }
        )
        .id(currentArticle.id)
        // currentArticle に追従する zoom transition。
        // 詳細でカード遷移して C を見ていた場合、戻る時 A ではなく C のカードに
        // 縮小アニメーションするように。
        #if !os(macOS)
        .applyZoomTransitionIfPossible(sourceID: currentArticle.id, namespace: zoomNamespace)
        #endif
        // 詳細表示中の記事 id を共有して、フィード側で先回りスクロールできるように。
        .onAppear {
            ArticleNavigationContext.shared.setCurrentArticle(currentArticle.id)
        }
        .onChange(of: currentArticle.id) { _, newID in
            ArticleNavigationContext.shared.setCurrentArticle(newID)
        }
        .onDisappear {
            ArticleNavigationContext.shared.setCurrentArticle(nil)
        }
    }
}

#if !os(macOS)
private extension View {
    /// 名前空間がある時だけ navigationTransition を適用するヘルパー。
    @ViewBuilder
    func applyZoomTransitionIfPossible(sourceID: UUID, namespace: Namespace.ID?) -> some View {
        if let namespace {
            self.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            self
        }
    }
}
#endif

// MARK: - 表示モード

private enum DetailViewMode: String, CaseIterable {
    case reader = "リーダー"
    case aiSummary = "AI要約"
    case web = "Web"

    var icon: String {
        switch self {
        case .reader: "doc.richtext"
        case .aiSummary: "sparkles"
        case .web: "globe"
        }
    }
}

// MARK: - ArticleDetailView

struct ArticleDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let article: Article
    var previousArticle: Article? = nil
    var nextArticle: Article? = nil
    var onNavigatePrev: (() -> Void)? = nil
    var onNavigateNext: (() -> Void)? = nil
    @State private var extractedArticle: ReadabilityExtractor.Article?
    @State private var isLoading = true
    @State private var viewMode: DetailViewMode = .reader
    @State private var loadingStage: String = "記事ページを取得中..."
    @State private var showFailureNotice = false
    @State private var showScoreBreakdown = false
    @State private var webPage = ManagedWKWebView()
    @State private var readerPage = ManagedWKWebView()
    @State private var summaryPage = ManagedWKWebView()
    /// Reader / Web / AI要約 の各 WebView が初期状態（記事URL or 自前HTML）から
    /// 別 URL に遷移したかどうか。ナビ済みのモードではモードピッカーを隠して
    /// 戻る／リロードのバーだけを表示する。
    @State private var readerHasNavigated = false
    @State private var webHasNavigated = false
    @State private var summaryHasNavigated = false
    @State private var scrollState = ScrollState()

    var body: some View {
        contentView
        .navigationTitle(article.source?.name ?? "記事")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                // どのモードでもリンク先に遷移している間は、これらのボタンは
                // すべて「元記事」に対する操作なので意味が無い。隠す。
                if !readerHasNavigated && !webHasNavigated && !summaryHasNavigated {
                    Button {
                        article.isFavorite.toggle()
                        try? modelContext.save()
                    } label: {
                        Image(systemName: article.isFavorite ? "star.fill" : "star")
                            .foregroundStyle(article.isFavorite ? .yellow : .secondary)
                    }

                    Menu {
                        Link(destination: article.articleURL) {
                            Label("ブラウザで開く", systemImage: "safari")
                        }
                        ShareLink(item: article.articleURL) {
                            Label("共有", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            Task { await reprocessAI() }
                        } label: {
                            Label("AI処理を再実行", systemImage: "arrow.triangle.2.circlepath")
                        }
                        Button {
                            showScoreBreakdown = true
                        } label: {
                            Label("スコアの内訳", systemImage: "chart.bar.doc.horizontal")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        .task {
            await loadContent()
        }
        // モード切替時 / 抽出完了時は末尾判定をリセット。新画面の WebView から
        // 改めて contentSize / offset が報告されるまで、stale な値で
        // 前後カードがちらつかないように。
        .onChange(of: viewMode) {
            scrollState.isAtBottom = false
        }
        .onChange(of: isLoading) {
            scrollState.isAtBottom = false
        }
        .sheet(isPresented: $showScoreBreakdown) {
            ScoreBreakdownView(article: article, modelContainer: modelContext.container)
        }
        .onAppear {
            let wasUnread = !article.isRead
            article.isRead = true
            article.readAt = Date()
            try? modelContext.save()
            if wasUnread {
                // 既読化でペナルティが解除されるためスコアを再計算（再閲覧時は不要）
                let engine = InterestEngine(modelContainer: modelContext.container)
                engine.rescore(article: article)
            }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        ZStack {
            if isLoading {
                LoadingPreviewView(article: article, scrollState: scrollState)
                    .transition(.opacity)
            } else if let extracted = extractedArticle {
                #if os(macOS)
                macContent(extracted: extracted)
                    .transition(.opacity)
                #else
                iosContent(extracted: extracted)
                    .transition(.opacity)
                #endif
            } else {
                ArticleWebView(url: article.articleURL, page: webPage, scrollState: scrollState)
                    .ignoresSafeArea()
                    .safeAreaInset(edge: .bottom) {
                        if !scrollState.barsHidden {
                            WebNavBar(page: webPage)
                                .padding(.bottom, 8)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: isLoading)
        .overlay(alignment: .bottom) {
            if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        #if !os(macOS)
                        .controlSize(.small)
                        #endif
                    Text(loadingStage)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .contentTransition(.opacity)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.regularMaterial)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if showFailureNotice {
                HStack(spacing: 12) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("リーダー抽出に失敗しました")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Button {
                        Task { await retryReader() }
                    } label: {
                        Text("再読み込み")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    Button {
                        showFailureNotice = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.regularMaterial)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: loadingStage)
        .animation(.easeInOut(duration: 0.3), value: showFailureNotice)
        .overlay(alignment: .bottom) {
            if shouldShowPrevNextCards {
                PrevNextCardsOverlay(
                    previous: previousArticle,
                    next: nextArticle,
                    isAtBottom: scrollState.isAtBottom,
                    onTapPrev: { onNavigatePrev?() },
                    onTapNext: { onNavigateNext?() }
                )
            }
        }
    }

    /// 前後カードを表示すべき状況かどうか。
    /// - ロード中（リーダー抽出中の RSS 概要画面）でも表示する
    /// - リーダー抽出失敗 → Web フォールバックでは表示しない（記事と重なるため）
    /// - Web モードでも表示しない（同上）
    /// - リーダー / AI 要約モードで、抽出済みの場合のみ表示
    private var shouldShowPrevNextCards: Bool {
        if isLoading { return true }
        guard extractedArticle != nil else { return false }
        return viewMode != .web
    }

    #if os(macOS)
    private func macContent(extracted: ReadabilityExtractor.Article) -> some View {
        ZStack {
            switch viewMode {
            case .reader:
                ReaderView(
                    article: article,
                    extracted: extracted,
                    page: readerPage,
                    hasNavigated: $readerHasNavigated,
                    scrollState: scrollState
                )
                .safeAreaInset(edge: .bottom) {
                    if readerHasNavigated {
                        WebNavBar(page: readerPage, onBackBeyondHistory: restoreReader(extracted: extracted))
                            .padding(.bottom, 8)
                    }
                }
            case .aiSummary:
                AISummaryView(
                    article: article,
                    page: summaryPage,
                    hasNavigated: $summaryHasNavigated,
                    scrollState: scrollState
                )
                .safeAreaInset(edge: .bottom) {
                    if summaryHasNavigated {
                        WebNavBar(page: summaryPage, onBackBeyondHistory: restoreSummary())
                            .padding(.bottom, 8)
                    }
                }
            case .web:
                ArticleWebView(url: article.articleURL, page: webPage, hasNavigated: $webHasNavigated, scrollState: scrollState)
                    .safeAreaInset(edge: .bottom) {
                        WebNavBar(page: webPage)
                            .padding(.bottom, 8)
                    }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("表示モード", selection: $viewMode) {
                    ForEach(DetailViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
            }
        }
    }
    #else
    private func iosContent(extracted: ReadabilityExtractor.Article) -> some View {
        DetailPagingView(
            article: article,
            extracted: extracted,
            webPage: webPage,
            readerPage: readerPage,
            summaryPage: summaryPage,
            readerHasNavigated: $readerHasNavigated,
            webHasNavigated: $webHasNavigated,
            summaryHasNavigated: $summaryHasNavigated,
            scrollState: scrollState,
            selection: $viewMode
        )
        .ignoresSafeArea()
        .safeAreaInset(edge: .bottom) {
            if !scrollState.barsHidden {
                let hasNavigated: Bool = {
                    switch viewMode {
                    case .reader: return readerHasNavigated
                    case .web: return webHasNavigated
                    case .aiSummary: return summaryHasNavigated
                    }
                }()
                VStack(spacing: 8) {
                    // 戻る／リロードバー: Web は元々常時表示、Reader/AI要約 はナビ済み時のみ。
                    switch viewMode {
                    case .web:
                        WebNavBar(page: webPage)
                    case .reader:
                        if readerHasNavigated {
                            WebNavBar(page: readerPage, onBackBeyondHistory: restoreReader(extracted: extracted))
                        }
                    case .aiSummary:
                        if summaryHasNavigated {
                            WebNavBar(page: summaryPage, onBackBeyondHistory: restoreSummary())
                        }
                    }
                    // モードピッカー: 元の状態にいる時だけ表示。
                    // リンク先に遷移してる時はモード切替の意味が無いので隠す。
                    if !hasNavigated {
                        HStack(spacing: 8) {
                            ForEach(DetailViewMode.allCases, id: \.self) { mode in
                                DetailModeButton(
                                    mode: mode,
                                    isSelected: viewMode == mode,
                                    isProcessing: mode == .aiSummary && AIProgressTracker.shared.isProcessing(article.id)
                                ) {
                                    withAnimation { viewMode = mode }
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: viewMode) {
            withAnimation(.easeInOut(duration: 0.25)) {
                scrollState.barsHidden = false
            }
        }
    }
    #endif

    private func retryReader() async {
        showFailureNotice = false
        loadingStage = "記事ページを取得中..."
        isLoading = true
        await loadContent()
    }

    /// ナビバーの戻るが履歴外（リーダーのHTMLは backForwardList に積まれない）に達した時に
    /// リーダーHTML を再ロードして元に戻すクロージャを返す。
    private func restoreReader(extracted: ReadabilityExtractor.Article) -> () -> Void {
        return { [readerPage, article] in
            readerPage.load(
                html: ReaderView.buildReaderHTML(article: article, extracted: extracted),
                baseURL: article.articleURL
            )
        }
    }

    /// AI 要約モードでナビ済みになった時に元の AI 要約 HTML を再ロードする。
    private func restoreSummary() -> () -> Void {
        return { [summaryPage, article] in
            summaryPage.load(
                html: AISummaryView.buildSummaryHTML(article: article),
                baseURL: URL(string: "about:blank")!
            )
        }
    }

    private func reprocessAI() async {
        let aid = article.id
        guard !AIProgressTracker.shared.isProcessing(aid) else { return }
        let container = modelContext.container
        let articleID = article.persistentModelID
        if let extracted = extractedArticle {
            article.extractedBody = extracted.textContent
        }
        let task = Task.detached { @MainActor in
            defer { AIProgressTracker.shared.finish(aid) }
            let processor = AIProcessor(modelContainer: container)
            await processor.reprocess(articleID: articleID)
        }
        AIProgressTracker.shared.start(aid, task: task)
        await task.value
    }

    private func loadContent() async {
        let cacheID = article.id
        let extracted: ReadabilityExtractor.Article?
        if let cached = ReaderCache.shared.get(cacheID) {
            extracted = cached
        } else {
            let extractor = ReadabilityExtractor()
            extracted = await extractor.extract(from: article.articleURL) { stage in
                loadingStage = stage
            }
            if let extracted {
                ReaderCache.shared.set(extracted, for: cacheID)
            }
        }
        extractedArticle = extracted
        isLoading = false

        if extracted == nil {
            showFailureNotice = true
        }

        if extracted != nil {
            viewMode = .reader
        }

        // 全文が取れたらAI要約を実行（キャッシュにない & 処理中でない場合）
        if let extracted, AISummaryCache.shared.get(article.id) == nil,
           !AIProgressTracker.shared.isProcessing(article.id) {
            article.extractedBody = extracted.textContent
            let container = modelContext.container
            let articleID = article.persistentModelID
            let aid = article.id
            let task = Task.detached { @MainActor in
                defer { AIProgressTracker.shared.finish(aid) }
                let processor = AIProcessor(modelContainer: container)
                await processor.analyze(articleID: articleID)
            }
            AIProgressTracker.shared.start(aid, task: task)
        }
    }
}

// MARK: - ローディング中プレビュー

private struct LoadingPreviewView: View {
    let article: Article
    var scrollState: ScrollState? = nil

    var body: some View {
        // SwiftUI ScrollView では adjustedContentInset を取れず natural max が
        // 推測になってしまうので、UIScrollView (UIViewRepresentable) で囲んで
        // WKWebView と同じ要領で厳密値を取る。
        #if os(iOS) || os(visionOS)
        UIKitScrollHost(scrollState: scrollState) {
            previewContent
        }
        // 他のモード（リーダー / AI 要約 / Web）と揃えて safe area まで
        // コンテンツが広がるように。`safeAreaRegions = []` だけだと
        // UIScrollView の frame 自体が safe area 内に留まるので不十分。
        .ignoresSafeArea()
        #else
        // macOS は NSScrollView の挙動が素直で natural max ≒ contentSize - container
        // なので SwiftUI ScrollView + onScrollGeometryChange で済む。
        ScrollView {
            previewContent
        }
        .onScrollGeometryChange(for: Bool.self, of: { geom in
            let max = geom.contentSize.height - geom.containerSize.height
            if max <= 0 { return true }
            return geom.contentOffset.y >= max - 5
        }) { _, isBottom in
            scrollState?.isAtBottom = isBottom
        }
        #endif
    }

    private var previewContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(article.title)
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                let name = article.source?.name ?? article.sourceName
                if !name.isEmpty {
                    Text(name)
                }
                if let date = article.publishedAt {
                    Text("・")
                    Text(DateFormatter.localizedString(from: date, dateStyle: .long, timeStyle: .short))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let imageURL = article.displayImageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fit)
                    case .failure:
                        EmptyView()
                    default:
                        Color.gray.opacity(0.1).aspectRatio(16.0/9.0, contentMode: .fit)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let desc = article.cardDescription, !desc.isEmpty {
                Text(desc)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .padding(.bottom, 200)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }
}

#if os(iOS) || os(visionOS)
/// SwiftUI の content を UIScrollView でラップして、`adjustedContentInset` まで
/// 含めた正確な末尾判定を可能にする UIViewRepresentable。
/// SwiftUI ScrollView の `onScrollGeometryChange` では届かない値を取得するため。
private struct UIKitScrollHost<Content: View>: UIViewRepresentable {
    var scrollState: ScrollState?
    @ViewBuilder var content: () -> Content

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.alwaysBounceVertical = true
        sv.backgroundColor = .clear

        let host = UIHostingController(rootView: content())
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        // SwiftUI 側の safe area 設定を hosting 越しでも効かせるため container 扱いを外す。
        // LoadingPreviewView でも他モードと揃えてコンテンツが safe area まで広がる。
        host.safeAreaRegions = []
        sv.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: sv.contentLayoutGuide.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: sv.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: sv.contentLayoutGuide.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: sv.contentLayoutGuide.bottomAnchor),
            host.view.widthAnchor.constraint(equalTo: sv.frameLayoutGuide.widthAnchor),
        ])
        context.coordinator.host = host
        context.coordinator.attach(scrollState: scrollState, to: sv)
        return sv
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.host?.rootView = content()
        context.coordinator.scrollState = scrollState
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    class Coordinator: NSObject {
        var host: UIHostingController<Content>?
        var scrollState: ScrollState?
        private var offsetObs: NSKeyValueObservation?

        func attach(scrollState: ScrollState?, to sv: UIScrollView) {
            self.scrollState = scrollState
            self.offsetObs = sv.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
                let offsetY = sv.contentOffset.y
                let containerH = sv.bounds.size.height
                let contentH = sv.contentSize.height
                let insetB = sv.adjustedContentInset.bottom
                Task { @MainActor [weak self] in
                    self?.report(offsetY: offsetY, containerH: containerH, contentH: contentH, insetB: insetB)
                }
            }
        }

        private func report(offsetY: CGFloat, containerH: CGFloat, contentH: CGFloat, insetB: CGFloat) {
            guard contentH > 0 else {
                scrollState?.isAtBottom = false
                return
            }
            let maxOffsetY = contentH + insetB - containerH
            if maxOffsetY <= 0 {
                scrollState?.isAtBottom = true
                return
            }
            scrollState?.isAtBottom = offsetY >= maxOffsetY - 5
        }
    }
}
#endif

// MARK: - 前後記事カード Overlay

/// 記事末尾近くまでスクロールすると左下と右下に fade-in する前後記事カード。
/// タップで `currentArticle` が差し替わる（その場で記事遷移）。
fileprivate struct PrevNextCardsOverlay: View {
    let previous: Article?
    let next: Article?
    let isAtBottom: Bool
    let onTapPrev: () -> Void
    let onTapNext: () -> Void

    private var bottomPadding: CGFloat {
        #if os(macOS)
        // ロード中の status capsule が contentView 下から 20pt + 高さ ~50pt なので
        // その上に cards を載せるためには 80pt 以上必要。少し余裕を取って 88。
        return 88
        #else
        return 100
        #endif
    }

    var body: some View {
        if previous == nil && next == nil {
            EmptyView()
        } else {
            HStack(alignment: .bottom, spacing: 10) {
                Spacer(minLength: 0)
                if let prev = previous {
                    NavArticleCard(article: prev, direction: .previous, action: onTapPrev, isVisible: isAtBottom)
                        .frame(maxWidth: 280)
                } else {
                    Color.clear.frame(maxWidth: 280, maxHeight: 1)
                }
                if let next = next {
                    NavArticleCard(article: next, direction: .next, action: onTapNext, isVisible: isAtBottom)
                        .frame(maxWidth: 280)
                } else {
                    Color.clear.frame(maxWidth: 280, maxHeight: 1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, bottomPadding)
            .allowsHitTesting(isAtBottom)
            // 補助ナビゲーション用の小さな card なので Dynamic Type の
            // accessibility サイズまでは追従させない（画面より大きくなるのを防ぐ）。
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }
    }
}

fileprivate struct NavArticleCard: View {
    let article: Article
    let direction: Direction
    let action: () -> Void
    let isVisible: Bool
    @State private var isPressed = false

    enum Direction {
        case previous, next
    }

    private var label: String {
        direction == .previous ? "前の記事" : "次の記事"
    }

    private var chevron: String {
        direction == .previous ? "chevron.left" : "chevron.right"
    }

    /// 隠れている時の x オフセット。
    /// 「前の記事」は左に少し沈み、「次の記事」は右に少し沈む。
    /// 表示時にそれぞれ画面中央側へスライドインしてくる。
    private var hiddenOffsetX: CGFloat {
        direction == .previous ? -24 : 24
    }

    /// 表示時に「次の記事」の方が少し遅れて出ることで stagger 感を出す。
    private var entranceDelay: Double {
        direction == .next ? 0.07 : 0
    }

    var body: some View {
        Button(action: action) {
            // Card のサイズはテキスト content が駆動する。
            // 画像とグラデは .background で「サイズに寄与しない layer」として
            // 重ねるので、AsyncImage が原寸まで膨らんで card を画面外に
            // はみ出させたり、固定 height が JP の line-height で足りなく
            // なったりすることが無い。
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if direction == .previous {
                        Image(systemName: chevron)
                            .font(.caption2.weight(.bold))
                    }
                    Text(label)
                        .font(.caption2.weight(.semibold))
                    if direction == .next {
                        Image(systemName: chevron)
                            .font(.caption2.weight(.bold))
                    }
                }
                .foregroundStyle(.primary.opacity(0.75))

                Text(article.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 短い記事 / 1 行 title でも card が極端に小さくならないように
            // 最低 96pt は確保。content が大きい時は自然に伸びる。
            .frame(minHeight: 96, alignment: .bottomLeading)
            .background {
                // 上は透明、下に向かって `.regularMaterial` が濃くなるグラデーション。
                // ライト / ダークモードで OS が自動で適応するので、画像がよく見えつつ
                // 下部のテキストが両モードで読める。
                Rectangle()
                    .fill(.regularMaterial)
                    .mask {
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.6), .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
            }
            .background {
                imageBackground
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.22), radius: 14, y: 4)
            .scaleEffect(isPressed ? 0.96 : (isVisible ? 1.0 : 0.92))
            .opacity(isVisible ? 1 : 0)
            .offset(x: isVisible ? 0 : hiddenOffsetX, y: isVisible ? 0 : 24)
            .animation(.spring(response: 0.5, dampingFraction: 0.78).delay(entranceDelay), value: isVisible)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        #if os(visionOS)
        .hoverEffect()
        #endif
    }

    @ViewBuilder
    private var imageBackground: some View {
        if let url = article.displayImageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(LinearGradient(
                colors: [Color.gray.opacity(0.4), Color.gray.opacity(0.6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
    }
}

// MARK: - AI要約ビュー

fileprivate struct AISummaryView: View {
    let article: Article
    /// WebView インスタンスは親に持ち上げてある（ナビ済み状態を親と共有するため）。
    let page: ManagedWKWebView
    @Binding var hasNavigated: Bool
    var scrollState: ScrollState? = nil

    /// AI 要約の HTML 自体は about:blank で読み込んでいるので、
    /// 「ナビ済み = page.url が about:blank 以外の URL になった状態」と判定する。
    private static func isOriginalURL(_ url: URL?) -> Bool {
        guard let url else { return true }
        return url.absoluteString == "about:blank"
    }

    private var isAIProcessing: Bool {
        AIProgressTracker.shared.isProcessing(article.id)
    }

    private var summary: String? {
        AISummaryCache.shared.get(article.id)
    }

    private static let shimmerHTML = """
    <div class="shimmer-block"></div>
    <div class="shimmer-block" style="width:80%"></div>
    <div class="shimmer-block" style="width:60%"></div>
    """

    /// カテゴリ・キーワードの状態をまとめた識別子。これが変わったら
    /// AI 結果が変わったということなので HTML 全体を再ロードする。
    private var aiResultKey: String {
        "\(article.aiCategory ?? "(nil)")|\(article.keywordsRaw)|\(article.keywordsEnRaw)"
    }

    var body: some View {
        ConfiguredWebView(page: page, scrollState: scrollState)
            .task {
                page.load(html: buildSummaryHTML(), baseURL: URL(string: "about:blank")!)
            }
            .onChange(of: page.url) { _, newURL in
                hasNavigated = !Self.isOriginalURL(newURL)
            }
            .onChange(of: summary) {
                let html: String
                if let summary, !summary.isEmpty {
                    html = Self.markdownToHTML(summary)
                } else {
                    // キャッシュクリア時（再処理開始時など）はshimmerに戻す
                    html = Self.shimmerHTML
                }
                let escaped = html
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                    .replacingOccurrences(of: "\n", with: "\\n")
                Task {
                    try? await page.callJavaScript("document.getElementById('summary').innerHTML = '\(escaped)';")
                }
            }
            .onChange(of: aiResultKey) {
                // カテゴリ・キーワードが変わったら HTML 全体を再ロード
                // （JS で summary 部分しか更新していないため）
                page.load(html: buildSummaryHTML(), baseURL: URL(string: "about:blank")!)
            }
    }

    private func buildSummaryHTML() -> String {
        Self.buildSummaryHTML(article: article)
    }

    /// 親（ArticleDetailView）から復帰用に再ロード時にも使うため static にしてある。
    fileprivate static func buildSummaryHTML(article: Article) -> String {
        let summary = AISummaryCache.shared.get(article.id) ?? ""
        let title = escapeHTML(article.title)
        let sourceName = escapeHTML(article.source?.name ?? "")
        let dateStr = article.publishedAt.map {
            DateFormatter.localizedString(from: $0, dateStyle: .long, timeStyle: .short)
        } ?? ""

        let keywordsHTML = article.keywords.isEmpty ? "" : {
            let tags = article.keywords.map { "<span class=\"tag keyword\">\(escapeHTML($0))</span>" }.joined()
            return "<div class=\"tags\">\(tags)</div>"
        }()

        let categoriesHTML: String
        if !article.categories.isEmpty {
            let tags = article.categories.map { "<span class=\"tag category\">\(escapeHTML($0))</span>" }.joined()
            categoriesHTML = "<div class=\"tags\">\(tags)</div>"
        } else if article.classificationFailed {
            let label = article.classificationRefused ? "対象外" : "分類失敗"
            categoriesHTML = "<div class=\"tags\"><span class=\"tag category\">\(label)</span></div>"
        } else {
            categoriesHTML = ""
        }

        // Markdown→HTML簡易変換
        let summaryHTML = summary.isEmpty ? "" : markdownToHTML(summary)

        let shimmerHTML = """
        <div class="shimmer-block"></div>
        <div class="shimmer-block" style="width:80%"></div>
        <div class="shimmer-block" style="width:60%"></div>
        """

        return """
        <!DOCTYPE html>
        <html lang="ja">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=3">
        <style>
        :root { color-scheme: light dark; }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font: -apple-system-body;
            line-height: 1.8;
            color: #1d1d1f;
            background: #fff;
            padding: 20px 20px 200px;
            max-width: 720px;
            margin: 0 auto;
            -webkit-text-size-adjust: 100%;
        }
        @media (prefers-color-scheme: dark) {
            body { color: #f5f5f7; background: #1c1c1e; }
            .meta { color: #98989d; }
            hr { border-color: #38383a; }
            .summary h2, .summary h3, .summary h4 { color: #f5f5f7; }
            table { border-color: #48484a; }
            th { background: #2c2c2e; }
            th, td { border-color: #48484a; }
            .tag.keyword { background: rgba(50,130,246,0.2); color: #64a8ff; }
            .tag.category { background: rgba(255,159,10,0.2); color: #ffa33a; }
        }
        h1 { font: -apple-system-title2; line-height: 1.4; margin-bottom: 8px; font-weight: 700; }
        .meta { font: -apple-system-footnote; color: #86868b; margin-bottom: 16px; }
        .ai-label {
            font: -apple-system-subheadline; font-weight: 600; color: #007aff;
            margin-bottom: 12px;
        }
        hr { border: none; border-top: 1px solid #d2d2d7; margin: 16px 0; }
        .summary p { margin-bottom: 14px; }
        .summary h2 { font: -apple-system-title3; margin: 24px 0 10px; font-weight: 700; color: #1d1d1f; }
        .summary h3 { font: -apple-system-headline; margin: 20px 0 8px; color: #1d1d1f; }
        .summary h4 { font: -apple-system-callout; margin: 18px 0 6px; font-weight: 600; color: #1d1d1f; }
        .summary ul, .summary ol { padding-left: 24px; margin: 10px 0; }
        .summary li { margin-bottom: 6px; }
        .summary strong { font-weight: 600; }
        .summary blockquote {
            border-left: 3px solid #d2d2d7; margin: 14px 0;
            padding: 8px 16px; color: #6e6e73; font-style: italic;
        }
        table { font: -apple-system-subheadline; border-collapse: collapse; width: 100%; margin: 14px 0; }
        th, td { border: 1px solid #d2d2d7; padding: 8px 12px; text-align: left; }
        th { background: #f5f5f7; font-weight: 600; }
        .tags { margin-top: 8px; display: flex; flex-wrap: wrap; gap: 6px; }
        .tag {
            font: -apple-system-footnote; padding: 4px 10px; border-radius: 20px; display: inline-block;
        }
        .tag.keyword { background: rgba(50,130,246,0.1); color: #007aff; }
        .tag.category { background: rgba(255,159,10,0.1); color: #ff9500; }
        .shimmer-block {
            height: 16px; border-radius: 8px; margin-bottom: 12px;
            background: linear-gradient(90deg, #e0e0e0 25%, #f0f0f0 50%, #e0e0e0 75%);
            background-size: 200% 100%;
            animation: shimmer 1.5s infinite;
        }
        @keyframes shimmer {
            0% { background-position: 200% 0; }
            100% { background-position: -200% 0; }
        }
        @media (prefers-color-scheme: dark) {
            .shimmer-block {
                background: linear-gradient(90deg, #3a3a3c 25%, #48484a 50%, #3a3a3c 75%);
                background-size: 200% 100%;
            }
        }
        </style>
        </head>
        <body>
            <h1>\(title)</h1>
            <div class="meta">\(sourceName)　\(escapeHTML(dateStr))</div>
            <div class="ai-label">✦ AI要約</div>
            <div id="summary" class="summary">\(summaryHTML.isEmpty ? shimmerHTML : summaryHTML)</div>
            \(keywordsHTML.isEmpty && categoriesHTML.isEmpty ? "" : "<hr>" + keywordsHTML + categoriesHTML)
        </body>
        </html>
        """
    }

    private static func markdownToHTML(_ markdown: String) -> String {
        var html = ""
        var inList = false
        var inTable = false
        var tableHeaderDone = false

        let lines = markdown.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if inList { html += "</ul>"; inList = false }
                if inTable { html += "</tbody></table>"; inTable = false; tableHeaderDone = false }
                continue
            }

            // テーブル区切り行（|---|---|）はスキップ
            if trimmed.hasPrefix("|") && trimmed.contains("---") {
                tableHeaderDone = true
                continue
            }

            // テーブル行
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                if !inTable {
                    if inList { html += "</ul>"; inList = false }
                    html += "<table><thead>"
                    inTable = true
                    tableHeaderDone = false
                }
                let cells = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if !tableHeaderDone {
                    html += "<tr>" + cells.map { "<th>\(inlineMarkdown($0))</th>" }.joined() + "</tr></thead><tbody>"
                } else {
                    html += "<tr>" + cells.map { "<td>\(inlineMarkdown($0))</td>" }.joined() + "</tr>"
                }
                continue
            }

            if inTable { html += "</tbody></table>"; inTable = false; tableHeaderDone = false }

            // 見出し
            if trimmed.hasPrefix("#### ") {
                if inList { html += "</ul>"; inList = false }
                html += "<h4>\(inlineMarkdown(String(trimmed.dropFirst(5))))</h4>"
            } else if trimmed.hasPrefix("### ") {
                if inList { html += "</ul>"; inList = false }
                html += "<h3>\(inlineMarkdown(String(trimmed.dropFirst(4))))</h3>"
            } else if trimmed.hasPrefix("## ") {
                if inList { html += "</ul>"; inList = false }
                html += "<h2>\(inlineMarkdown(String(trimmed.dropFirst(3))))</h2>"
            }
            // リスト
            else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("・") {
                if !inList { html += "<ul>"; inList = true }
                let content = trimmed.replacingOccurrences(of: "^[・\\-\\*]\\s*", with: "", options: .regularExpression)
                html += "<li>\(inlineMarkdown(content))</li>"
            }
            // 通常の段落
            else {
                if inList { html += "</ul>"; inList = false }
                html += "<p>\(inlineMarkdown(trimmed))</p>"
            }
        }
        if inList { html += "</ul>" }
        if inTable { html += "</tbody></table>" }
        return html
    }

    private static func inlineMarkdown(_ text: String) -> String {
        var result = escapeHTML(text)
        // **bold**
        result = result.replacingOccurrences(
            of: "\\*\\*(.+?)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
        // `code`
        result = result.replacingOccurrences(
            of: "`(.+?)`", with: "<code>$1</code>", options: .regularExpression)
        return result
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}


// MARK: - Shimmer

private struct ShimmerView: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        LinearGradient(
            colors: [.gray.opacity(0.15), .gray.opacity(0.3), .gray.opacity(0.15)],
            startPoint: .init(x: phase - 0.5, y: 0.5),
            endPoint: .init(x: phase + 0.5, y: 0.5)
        )
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                phase = 1.5
            }
        }
    }
}

// MARK: - UIPageViewController Paging (iOS)

#if !os(macOS)
private struct DetailPagingView: UIViewControllerRepresentable {
    let article: Article
    let extracted: ReadabilityExtractor.Article
    let webPage: ManagedWKWebView
    let readerPage: ManagedWKWebView
    let summaryPage: ManagedWKWebView
    @Binding var readerHasNavigated: Bool
    @Binding var webHasNavigated: Bool
    @Binding var summaryHasNavigated: Bool
    let scrollState: ScrollState
    @Binding var selection: DetailViewMode

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        let initial = context.coordinator.viewController(for: .reader)
        pvc.setViewControllers([initial], direction: .forward, animated: false)
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        let current = context.coordinator.currentMode
        if selection != current {
            let direction: UIPageViewController.NavigationDirection =
                DetailViewMode.allCases.firstIndex(of: selection)! > DetailViewMode.allCases.firstIndex(of: current)!
                ? .forward : .reverse
            let vc = context.coordinator.viewController(for: selection)
            pvc.setViewControllers([vc], direction: direction, animated: true)
            context.coordinator.currentMode = selection
        }
    }

    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        let parent: DetailPagingView
        var currentMode: DetailViewMode = .reader
        private var controllers: [DetailViewMode: UIViewController] = [:]

        init(_ parent: DetailPagingView) {
            self.parent = parent
        }

        func viewController(for mode: DetailViewMode) -> UIViewController {
            if let existing = controllers[mode] { return existing }
            let vc: UIViewController
            switch mode {
            case .reader:
                let host = UIHostingController(rootView: ReaderView(
                    article: parent.article,
                    extracted: parent.extracted,
                    page: parent.readerPage,
                    hasNavigated: parent.$readerHasNavigated,
                    scrollState: parent.scrollState
                ))
                applyTransparency(host)
                vc = host
            case .aiSummary:
                let host = UIHostingController(rootView: AISummaryView(
                    article: parent.article,
                    page: parent.summaryPage,
                    hasNavigated: parent.$summaryHasNavigated,
                    scrollState: parent.scrollState
                ))
                applyTransparency(host)
                vc = host
            case .web:
                let host = UIHostingController(rootView: ArticleWebView(
                    url: parent.article.articleURL,
                    page: parent.webPage,
                    hasNavigated: parent.$webHasNavigated,
                    scrollState: parent.scrollState
                ))
                applyTransparency(host)
                vc = host
            }
            controllers[mode] = vc
            return vc
        }

        /// UIHostingController を透過にしつつ container safe area の自動取り扱いを切る。
        /// - 不透明 view が safe area まで色を塗ってしまう問題と
        /// - 内部の SwiftUI `.ignoresSafeArea()` が hosting 越しに無視される問題
        /// の両方を解決する。
        private func applyTransparency<Content: View>(_ host: UIHostingController<Content>) {
            host.view.backgroundColor = .clear
            host.safeAreaRegions = []
        }

        private func mode(for viewController: UIViewController) -> DetailViewMode? {
            controllers.first { $0.value === viewController }?.key
        }

        // MARK: DataSource

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let mode = mode(for: viewController),
                  let index = DetailViewMode.allCases.firstIndex(of: mode),
                  index > 0 else { return nil }
            return self.viewController(for: DetailViewMode.allCases[index - 1])
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let mode = mode(for: viewController),
                  let index = DetailViewMode.allCases.firstIndex(of: mode),
                  index < DetailViewMode.allCases.count - 1 else { return nil }
            return self.viewController(for: DetailViewMode.allCases[index + 1])
        }

        // MARK: Delegate

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let visible = pvc.viewControllers?.first,
                  let mode = mode(for: visible) else { return }
            currentMode = mode
            DispatchQueue.main.async {
                self.parent.selection = mode
            }
        }
    }
}
#endif

// MARK: - Detail Mode Button

private struct DetailModeButton: View {
    let mode: DetailViewMode
    let isSelected: Bool
    var isProcessing: Bool = false
    let action: () -> Void

    @State private var symbolEffect = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: mode.icon)
                    .font(.callout)
                    .symbolEffect(.rotate, isActive: isProcessing)
                    .symbolEffect(.pulse, isActive: isProcessing)
                Text(mode.rawValue)
                    .font(.caption2)
            }
            .frame(width: 56, height: 40)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        #if os(visionOS)
        .buttonStyle(.bordered)
        #else
        .buttonStyle(.glassProminent)
        #endif
        .tint(isSelected ? .accentColor : .clear)
    }
}

fileprivate struct ReaderView: View {
    let article: Article
    let extracted: ReadabilityExtractor.Article
    /// WebView インスタンスは親に持ち上げてある。本文中の <a> をタップして外部 URL に
    /// 移動したかを親に通知する必要があるため、戻る／リロードのバーは親側 (iosContent) で表示する。
    let page: ManagedWKWebView
    @Binding var hasNavigated: Bool
    var scrollState: ScrollState? = nil

    var body: some View {
        ConfiguredWebView(page: page, scrollState: scrollState)
            .task {
                // baseURL に元記事の URL を渡すことで、相対リンク／画像の解決と
                // 埋め込み iframe（YouTube 等）の origin チェック通過に必要な
                // 親ページ origin を提供する。about:blank だと YouTube の embed が
                // エラー 153（プレーヤー設定エラー）で再生できない。
                page.load(html: buildReaderHTML(), baseURL: article.articleURL)
            }
            .onChange(of: page.url) { _, newURL in
                hasNavigated = newURL != nil && newURL != article.articleURL
            }
    }

    private func buildReaderHTML() -> String {
        Self.buildReaderHTML(article: article, extracted: extracted)
    }

    /// 親（ArticleDetailView）から戻るボタンの履歴外フォールバックで再ロード時にも使うため static にしてある。
    fileprivate static func buildReaderHTML(article: Article, extracted: ReadabilityExtractor.Article) -> String {
        let title = escapeHTML(extracted.title)
        let sourceName = escapeHTML(article.source?.name ?? extracted.siteName ?? "")
        let byline = extracted.byline.map { "　" + escapeHTML($0) } ?? ""
        let dateStr = article.publishedAt.map {
            DateFormatter.localizedString(from: $0, dateStyle: .long, timeStyle: .short)
        } ?? ""

        return """
        <!DOCTYPE html>
        <html lang="ja">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=3">
        <style>
        :root { color-scheme: light dark; }
        * { box-sizing: border-box; }
        body {
            font: -apple-system-body;
            line-height: 1.9;
            color: #1d1d1f;
            background: #fff;
            margin: 0;
            padding: 20px 20px 200px;
            max-width: 720px;
            margin: 0 auto;
            -webkit-text-size-adjust: 100%;
        }
        @media (prefers-color-scheme: dark) {
            body { color: #f5f5f7; background: #1c1c1e; }
            .meta { color: #98989d; }
            .content blockquote { border-color: #48484a; color: #98989d; }
            .content pre, .content code {
                background: #2c2c2e !important;
                color: #f5f5f7 !important;
            }
            .content pre *, .content code * {
                color: inherit !important;
                background: transparent !important;
            }
            .content th, .content td { border-color: #48484a; }
            .content a { color: #64d2ff; }
            hr { border-color: #38383a; }
        }
        h1 { font: -apple-system-title2; line-height: 1.4; margin: 0 0 8px; font-weight: 700; }
        .meta { font: -apple-system-footnote; color: #86868b; margin-bottom: 20px; }
        hr { border: none; border-top: 1px solid #d2d2d7; margin: 0 0 24px; }
        .content img {
            max-width: 100%; height: auto;
            border-radius: 8px; margin: 16px 0; display: block;
        }
        .content img.hero {
            margin-top: 0;
            margin-bottom: 24px;
        }
        .content p { margin: 0 0 18px; }
        .content h2 { font: -apple-system-title3; margin: 32px 0 12px; }
        .content h3 { font: -apple-system-headline; margin: 28px 0 10px; }
        .content h4 { font: -apple-system-callout; margin: 24px 0 8px; }
        .content ul, .content ol { padding-left: 24px; margin: 12px 0; }
        .content li { margin-bottom: 8px; }
        .content blockquote {
            border-left: 3px solid #d2d2d7; margin: 16px 0;
            padding: 8px 16px; color: #6e6e73; font-style: italic;
        }
        .content pre {
            font: -apple-system-footnote; background: #f5f5f7; border-radius: 8px;
            padding: 14px; overflow-x: auto; line-height: 1.5;
        }
        .content code { font: -apple-system-footnote; background: #f5f5f7; padding: 2px 6px; border-radius: 4px; }
        .content pre code { background: none; padding: 0; }
        .content table { border-collapse: collapse; width: 100%; margin: 16px 0; }
        .content th, .content td { border: 1px solid #d2d2d7; padding: 8px 12px; text-align: left; font: -apple-system-subheadline; }
        .content figure { margin: 16px 0; }
        .content figcaption { font: -apple-system-footnote; color: #86868b; text-align: center; margin-top: 6px; }
        .content a { color: #0066cc; text-decoration: none; }
        .content a:hover { text-decoration: underline; }
        .content video, .content iframe { max-width: 100%; }
        </style>
        </head>
        <body>
            <h1>\(title)</h1>
            <div class="meta">\(escapeHTML(sourceName))\(byline)　\(escapeHTML(dateStr))</div>
            <hr>
            <div class="content">\(heroImageHTML(article: article, extracted: extracted))\(extracted.content)</div>
            <script>
            // 読み込みに失敗した画像はプレースホルダを出さず非表示にする
            // (404 / 認証必須 / CORS ブロック等の broken image 対策)
            document.querySelectorAll('.content img').forEach(function(img) {
                img.addEventListener('error', function() { img.style.display = 'none'; });
                if (img.complete && img.naturalWidth === 0) img.style.display = 'none';
            });
            </script>
        </body>
        </html>
        """
    }

    /// Readability が落としがちな OG 画像を、本文に同じ URL が含まれていなければ先頭に補う。
    /// 画像のロードに失敗した場合（Qiita 等で OG URL が 404 を返すケース）はプレースホルダを
    /// 出さず非表示にする。
    fileprivate static func heroImageHTML(article: Article, extracted: ReadabilityExtractor.Article) -> String {
        guard let url = article.ogImageURL?.absoluteString, !url.isEmpty else { return "" }
        if extracted.content.range(of: url, options: .caseInsensitive) != nil { return "" }
        return "<img class=\"hero\" src=\"\(escapeHTML(url))\" onerror=\"this.style.display='none'\">"
    }

    fileprivate static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - ScrollState（Safari風バーの表示状態）

@Observable
final class ScrollState {
    var barsHidden: Bool = false
    /// 実コンテンツの末尾に viewport が到達したか（前後カード表示用）。
    var isAtBottom: Bool = false

    func reportScroll(oldY: CGFloat, newY: CGFloat) {
        let delta = newY - oldY
        guard abs(delta) > 10, newY > 50 else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            barsHidden = delta > 0
        }
    }

    /// WKWebView の `scrollView` から直接呼ばれる。
    /// 実 max scroll = `contentHeight + insetBottom - containerHeight`。
    /// `insetBottom` は `scrollView.adjustedContentInset.bottom`（safeAreaInset の
    /// mode picker / home indicator 分。SwiftUI WebView では取れない値）。
    func reportProgress(offsetY: CGFloat, containerHeight: CGFloat, contentHeight: CGFloat, insetBottom: CGFloat) {
        guard contentHeight > 0 else {
            isAtBottom = false
            return
        }
        let maxOffsetY = contentHeight + insetBottom - containerHeight
        if maxOffsetY <= 0 {
            isAtBottom = true
            return
        }
        let tolerance: CGFloat = 5
        isAtBottom = offsetY >= maxOffsetY - tolerance
    }
}

// MARK: - WKWebView ラッパー

/// target="_blank" や window.open() などの新規ウィンドウ要求を Safari に逃がす delegate。
@MainActor
final class WebNavDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        // targetFrame が nil = 新規ウィンドウへの遷移。現在の WebView で開かず外部に。
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            await openExternally(url)
            return .cancel
        }
        return .allow
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // window.open() などで decidePolicy を経由しない経路用のフォールバック。
        if let url = navigationAction.request.url {
            Task { await openExternally(url) }
        }
        return nil
    }

    private func openExternally(_ url: URL) async {
        #if os(iOS) || os(visionOS)
        await UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }
}

#if os(macOS)
/// macOS 用の scroll 末尾検出 JS。
/// WKWebView 内部の NSScrollView に SwiftUI 越しに触れないので、
/// JS の scroll event listener から native (WKScriptMessageHandler) に
/// `atBottom` を投げる方式を取る。
fileprivate let scrollListenerJS = """
(function() {
  if (window.__seektheaScrollHandlerInstalled) return;
  window.__seektheaScrollHandlerInstalled = true;
  function check() {
    var docHeight = document.documentElement.scrollHeight;
    var winHeight = window.innerHeight;
    var scrollY = window.scrollY || window.pageYOffset || 0;
    var atBottom = (scrollY + winHeight) >= (docHeight - 5);
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.scrollHandler) {
      window.webkit.messageHandlers.scrollHandler.postMessage({ atBottom: atBottom });
    }
  }
  window.addEventListener('scroll', check, { passive: true });
  window.addEventListener('resize', check, { passive: true });
  // 初期状態（scroll 不要で content がフィットしているケース）も判定する
  setTimeout(check, 100);
})();
"""

/// WKWebView 内 JS から scroll 末尾を通知してもらうための handler。
/// `WKScriptMessage` の name / body は MainActor 隔離されているので
/// handler 全体を @MainActor にして直接読む。
@MainActor
final class WebScrollMessageHandler: NSObject, WKScriptMessageHandler {
    var callback: ((Bool) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "scrollHandler" else { return }
        let atBottom: Bool? = (message.body as? [String: Any])?["atBottom"] as? Bool
        guard let atBottom else { return }
        callback?(atBottom)
    }
}
#endif

/// WKWebView を SwiftUI で扱うために @Observable で包む wrapper。
/// iOS 26 SwiftUI の `WebPage` と同等の API（load(html:) / callJavaScript /
/// url 観測 / backForwardList 等）を提供しつつ、WebPage では取れない
/// `scrollView.adjustedContentInset` などの UIKit 情報にもアクセスできる。
/// （前後カードの表示判定で本物の最大スクロール位置が必要なため）
@MainActor
@Observable
final class ManagedWKWebView {
    @ObservationIgnored let webView: WKWebView
    var url: URL?
    var isLoading: Bool = false

    @ObservationIgnored private let navDelegate: WebNavDelegate
    @ObservationIgnored private var urlObs: NSKeyValueObservation?
    @ObservationIgnored private var loadingObs: NSKeyValueObservation?

    #if os(macOS)
    /// macOS で scroll 末尾を検出した時に呼ばれる callback。
    /// `WrappedWKWebView` の Coordinator が ScrollState を更新する処理を
    /// 詰めるために使う（@MainActor）。
    @ObservationIgnored var onScrollAtBottomChange: ((Bool) -> Void)?
    @ObservationIgnored private let scrollMessageHandler: WebScrollMessageHandler
    #endif

    init() {
        let config = WKWebViewConfiguration()

        #if os(macOS)
        let handler = WebScrollMessageHandler()
        config.userContentController.add(handler, name: "scrollHandler")
        config.userContentController.addUserScript(WKUserScript(
            source: scrollListenerJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        self.scrollMessageHandler = handler
        #endif

        let wv = WKWebView(frame: .zero, configuration: config)
        let nd = WebNavDelegate()
        wv.navigationDelegate = nd
        wv.uiDelegate = nd

        // SwiftUI の WebView 互換の見た目に揃える。raw WKWebView のデフォルトだと
        // isOpaque = true で safe area まで真っ白／真っ黒に塗られてしまい、
        // .ignoresSafeArea で広げてもフルスクリーンに見えなくなる。
        #if os(iOS) || os(visionOS)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        #endif

        self.webView = wv
        self.navDelegate = nd

        // KVO 経由で WebPage 互換の url / isLoading を更新する。
        // observe コールバックは KVO スレッド（多くは UI スレッド）で来るが、
        // @MainActor isolation を確実にするため Task で MainActor へ。
        self.urlObs = wv.observe(\.url, options: [.initial, .new]) { [weak self] wv, _ in
            let newURL = wv.url
            Task { @MainActor [weak self] in self?.url = newURL }
        }
        self.loadingObs = wv.observe(\.isLoading, options: [.initial, .new]) { [weak self] wv, _ in
            let newLoading = wv.isLoading
            Task { @MainActor [weak self] in self?.isLoading = newLoading }
        }

        #if os(macOS)
        // self が完全初期化された後に callback を配線する。
        handler.callback = { [weak self] atBottom in
            self?.onScrollAtBottomChange?(atBottom)
        }
        #endif
    }

    func load(html: String, baseURL: URL?) {
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    func load(_ request: URLRequest) {
        webView.load(request)
    }

    func load(_ item: WKBackForwardListItem) {
        webView.go(to: item)
    }

    func reload() { webView.reload() }
    func stopLoading() { webView.stopLoading() }

    func callJavaScript(_ js: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(js, in: nil, contentWorld: .page)
    }

    var backForwardList: WKBackForwardList { webView.backForwardList }
}

#if canImport(UIKit)
/// SwiftUI の view tree に WKWebView を埋める Representable。
/// `manager.webView` をそのままホストする。複数の WrappedWKWebView が
/// 同じ manager を持つことは無い前提（モード毎に別 manager を割り当てる）。
struct WrappedWKWebView: UIViewRepresentable {
    let manager: ManagedWKWebView
    var scrollState: ScrollState? = nil

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.attach(scrollState: scrollState, to: manager.webView)
        return manager.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.scrollState = scrollState
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    class Coordinator: NSObject {
        var scrollState: ScrollState?
        private var offsetObs: NSKeyValueObservation?
        private var lastOffsetY: CGFloat = 0

        func attach(scrollState: ScrollState?, to webView: WKWebView) {
            self.scrollState = scrollState
            let sv = webView.scrollView
            self.offsetObs = sv.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
                let newY = sv.contentOffset.y
                let containerH = sv.bounds.size.height
                let contentH = sv.contentSize.height
                let insetB = sv.adjustedContentInset.bottom
                Task { @MainActor [weak self] in
                    self?.report(offsetY: newY, containerH: containerH, contentH: contentH, insetB: insetB)
                }
            }
        }

        private func report(offsetY: CGFloat, containerH: CGFloat, contentH: CGFloat, insetB: CGFloat) {
            scrollState?.reportScroll(oldY: lastOffsetY, newY: offsetY)
            scrollState?.reportProgress(
                offsetY: offsetY,
                containerHeight: containerH,
                contentHeight: contentH,
                insetBottom: insetB
            )
            lastOffsetY = offsetY
        }
    }
}
#elseif canImport(AppKit)
/// macOS 用。WKWebView を NSView としてホストする。
/// scroll 観測は ManagedWKWebView 側で JS scroll listener から
/// callback で受け取る形になっているので、ここで配線する。
struct WrappedWKWebView: NSViewRepresentable {
    let manager: ManagedWKWebView
    var scrollState: ScrollState? = nil

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.attach(manager: manager, scrollState: scrollState)
        return manager.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.scrollState = scrollState
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    class Coordinator {
        var scrollState: ScrollState?

        func attach(manager: ManagedWKWebView, scrollState: ScrollState?) {
            self.scrollState = scrollState
            manager.onScrollAtBottomChange = { [weak self] atBottom in
                self?.scrollState?.isAtBottom = atBottom
            }
        }
    }
}
#endif

/// アプリ内で WKWebView を表示する共通ラッパー。
fileprivate struct ConfiguredWebView: View {
    let page: ManagedWKWebView
    var scrollState: ScrollState? = nil

    var body: some View {
        WrappedWKWebView(manager: page, scrollState: scrollState)
    }
}

// MARK: - ArticleWebView（WKWebView + ManagedWKWebView）

struct ArticleWebView: View {
    let url: URL
    let page: ManagedWKWebView
    var hasNavigated: Binding<Bool>? = nil
    let scrollState: ScrollState

    var body: some View {
        ConfiguredWebView(page: page, scrollState: scrollState)
            .task(id: url) {
                if page.url != url {
                    page.load(URLRequest(url: url))
                }
            }
            .onChange(of: page.url) { _, newURL in
                hasNavigated?.wrappedValue = newURL != nil && newURL != url
            }
    }
}

// MARK: - WebNavBar（戻る・リロードの浮遊バー）

struct WebNavBar: View {
    let page: ManagedWKWebView
    /// ネイティブの戻る履歴（backForwardList）が空のときに代わりに呼ぶ閉包。
    /// 例: リーダーで `load(html:)` した後にリンク先へ移動した場合、その時点の
    /// backList は空のままなので戻る手段が無くなる。これを使ってリーダーHTMLの
    /// 再ロードなどに使う。
    var onBackBeyondHistory: (() -> Void)? = nil

    var body: some View {
        // URL変更を観測して再描画を促す（backForwardListだけでは追跡されない）
        let _ = page.url
        let _ = page.isLoading
        let canNativeBack = !page.backForwardList.backList.isEmpty

        HStack(spacing: 24) {
            Button {
                if canNativeBack, let item = page.backForwardList.backList.last {
                    page.load(item)
                } else {
                    onBackBeyondHistory?()
                }
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.title3)
            }
            .disabled(!canNativeBack && onBackBeyondHistory == nil)

            Button {
                if page.isLoading {
                    page.stopLoading()
                } else {
                    page.reload()
                }
            } label: {
                Image(systemName: page.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.title3)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
    }
}

// MARK: - FlowLayout

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangeSubviews(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}

