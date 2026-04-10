import SwiftUI
import SwiftData
import WebKit

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
    @State private var extractedArticle: ReadabilityExtractor.Article?
    @State private var isLoading = true
    @State private var isAIProcessing = false
    @State private var viewMode: DetailViewMode = .reader

    var body: some View {
        contentView
        .navigationTitle(article.source?.name ?? "記事")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                // リーダー抽出失敗時のリトライボタン
                if extractedArticle == nil && !isLoading {
                    Button {
                        Task { await retryReader() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }

                Button {
                    article.isFavorite.toggle()
                    try? modelContext.save()
                } label: {
                    Image(systemName: article.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(article.isFavorite ? .yellow : .secondary)
                }

                Link(destination: article.articleURL) {
                    Image(systemName: "safari")
                }

                ShareLink(item: article.articleURL) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .task {
            await loadContent()
        }
        .onAppear {
            if !article.isRead {
                article.isRead = true
                try? modelContext.save()
            }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if isLoading {
            ProgressView("記事を読み込み中...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let extracted = extractedArticle {
            #if os(macOS)
            macContent(extracted: extracted)
            #else
            iosContent(extracted: extracted)
            #endif
        } else {
            OriginalPageWebView(url: article.articleURL)
                .ignoresSafeArea()
        }
    }

    #if os(macOS)
    private func macContent(extracted: ReadabilityExtractor.Article) -> some View {
        ZStack {
            switch viewMode {
            case .reader:
                ReaderView(article: article, extracted: extracted)
            case .aiSummary:
                AISummaryView(article: article, isAIProcessing: isAIProcessing)
            case .web:
                OriginalPageWebView(url: article.articleURL)
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
            isAIProcessing: isAIProcessing,
            selection: $viewMode
        )
        .ignoresSafeArea()
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                ForEach(DetailViewMode.allCases, id: \.self) { mode in
                    DetailModeButton(
                        mode: mode,
                        isSelected: viewMode == mode,
                        isProcessing: mode == .aiSummary && isAIProcessing
                    ) {
                        withAnimation { viewMode = mode }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }
    #endif

    private func retryReader() async {
        isLoading = true
        await loadContent()
    }

    private func loadContent() async {
        let extractor = ReadabilityExtractor()
        let extracted = await extractor.extract(from: article.articleURL)
        extractedArticle = extracted
        isLoading = false

        if extracted != nil {
            viewMode = .reader
        }

        // 全文が取れたらAI要約を実行
        if let extracted, !article.isAIProcessed {
            article.extractedBody = extracted.textContent
            isAIProcessing = true
            let container = modelContext.container
            let articleID = article.persistentModelID
            Task.detached { @MainActor in
                let processor = AIProcessor(modelContainer: container)
                await processor.analyze(articleID: articleID)
                isAIProcessing = false
            }
        }
    }
}

// MARK: - AI要約ビュー

private struct AISummaryView: View {
    let article: Article
    var isAIProcessing: Bool
    @State private var webViewStore = SummaryWebViewStore()

    var body: some View {
        SummaryWebView(html: buildSummaryHTML(), store: webViewStore)
            .onChange(of: article.summary) {
                if let summary = article.summary, !summary.isEmpty {
                    webViewStore.updateSummary(markdownToHTML(summary))
                }
            }
    }

    private func buildSummaryHTML() -> String {
        let summary = article.summary ?? ""
        let title = escapeHTML(article.title)
        let sourceName = escapeHTML(article.source?.name ?? "")
        let dateStr = article.publishedAt.map {
            DateFormatter.localizedString(from: $0, dateStyle: .long, timeStyle: .short)
        } ?? ""

        let keywordsHTML = article.keywords.isEmpty ? "" : {
            let tags = article.keywords.map { "<span class=\"tag keyword\">\(escapeHTML($0))</span>" }.joined()
            return "<div class=\"tags\">\(tags)</div>"
        }()

        let categoriesHTML = article.categories.isEmpty ? "" : {
            let tags = article.categories.map { "<span class=\"tag category\">\(escapeHTML($0))</span>" }.joined()
            return "<div class=\"tags\">\(tags)</div>"
        }()

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
            font-family: -apple-system, "Hiragino Sans", "Hiragino Kaku Gothic ProN", sans-serif;
            font-size: 18px;
            line-height: 1.8;
            color: #1d1d1f;
            background: #fff;
            padding: 20px 20px 80px;
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
        h1 { font-size: 22px; line-height: 1.4; margin-bottom: 8px; font-weight: 700; }
        .meta { font-size: 13px; color: #86868b; margin-bottom: 16px; }
        .ai-label {
            font-size: 14px; font-weight: 600; color: #007aff;
            margin-bottom: 12px;
        }
        hr { border: none; border-top: 1px solid #d2d2d7; margin: 16px 0; }
        .summary p { margin-bottom: 14px; }
        .summary h2 { font-size: 20px; margin: 24px 0 10px; font-weight: 700; color: #1d1d1f; }
        .summary h3 { font-size: 18px; margin: 20px 0 8px; font-weight: 600; color: #1d1d1f; }
        .summary h4 { font-size: 16px; margin: 18px 0 6px; font-weight: 600; color: #1d1d1f; }
        .summary ul, .summary ol { padding-left: 24px; margin: 10px 0; }
        .summary li { margin-bottom: 6px; }
        .summary strong { font-weight: 600; }
        .summary blockquote {
            border-left: 3px solid #d2d2d7; margin: 14px 0;
            padding: 8px 16px; color: #6e6e73; font-style: italic;
        }
        table { border-collapse: collapse; width: 100%; margin: 14px 0; font-size: 15px; }
        th, td { border: 1px solid #d2d2d7; padding: 8px 12px; text-align: left; }
        th { background: #f5f5f7; font-weight: 600; }
        .tags { margin-top: 8px; display: flex; flex-wrap: wrap; gap: 6px; }
        .tag {
            font-size: 13px; padding: 4px 10px; border-radius: 20px; display: inline-block;
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

    private func markdownToHTML(_ markdown: String) -> String {
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

    private func inlineMarkdown(_ text: String) -> String {
        var result = escapeHTML(text)
        // **bold**
        result = result.replacingOccurrences(
            of: "\\*\\*(.+?)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
        // `code`
        result = result.replacingOccurrences(
            of: "`(.+?)`", with: "<code>$1</code>", options: .regularExpression)
        return result
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - Summary WebView

class SummaryWebViewStore {
    var webView: WKWebView?

    func updateSummary(_ html: String) {
        let escaped = html
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        let js = "document.getElementById('summary').innerHTML = '\(escaped)';"
        webView?.evaluateJavaScript(js)
    }
}

#if os(macOS)
private struct SummaryWebView: NSViewRepresentable {
    let html: String
    var store: SummaryWebViewStore?
    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.loadHTMLString(html, baseURL: nil)
        store?.webView = webView
        return webView
    }
    func updateNSView(_ webView: WKWebView, context: Context) {}
}
#else
private struct SummaryWebView: UIViewRepresentable {
    let html: String
    var store: SummaryWebViewStore?
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.loadHTMLString(html, baseURL: nil)
        store?.webView = webView
        return webView
    }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}
#endif

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
    let isAIProcessing: Bool
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
                let hc = UIHostingController(rootView: ReaderView(article: parent.article, extracted: parent.extracted))
                hc.safeAreaRegions = []
                vc = hc
            case .aiSummary:
                let hc = UIHostingController(rootView: AISummaryView(article: parent.article, isAIProcessing: parent.isAIProcessing))
                hc.safeAreaRegions = []
                vc = hc
            case .web:
                let webVC = UIViewController()
                let webView = WKWebView()
                webView.load(URLRequest(url: parent.article.articleURL))
                webVC.view = webView
                vc = webVC
            }
            controllers[mode] = vc
            return vc
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
        .buttonStyle(.glassProminent)
        .tint(isSelected ? .accentColor : .clear)
    }
}

private struct ReaderView: View {
    let article: Article
    let extracted: ReadabilityExtractor.Article

    var body: some View {
        ReaderWebView(html: buildReaderHTML())
    }

    private func buildReaderHTML() -> String {
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
            font-family: -apple-system, "Hiragino Sans", "Hiragino Kaku Gothic ProN", sans-serif;
            font-size: 17px;
            line-height: 1.9;
            color: #1d1d1f;
            background: #fff;
            margin: 0;
            padding: 20px 20px 80px;
            max-width: 720px;
            margin: 0 auto;
            -webkit-text-size-adjust: 100%;
        }
        @media (prefers-color-scheme: dark) {
            body { color: #f5f5f7; background: #1c1c1e; }
            .meta { color: #98989d; }
            a { color: #64d2ff; }
            blockquote { border-color: #48484a; color: #98989d; }
            pre, code { background: #2c2c2e; }
            th, td { border-color: #48484a; }
            hr { border-color: #38383a; }
        }
        h1 { font-size: 24px; line-height: 1.4; margin: 0 0 8px; font-weight: 700; }
        .meta { font-size: 13px; color: #86868b; margin-bottom: 20px; }
        hr { border: none; border-top: 1px solid #d2d2d7; margin: 0 0 24px; }
        .content img {
            max-width: 100%; height: auto;
            border-radius: 8px; margin: 16px 0; display: block;
        }
        .content p { margin: 0 0 18px; }
        .content h2 { font-size: 20px; margin: 32px 0 12px; }
        .content h3 { font-size: 18px; margin: 28px 0 10px; }
        .content h4 { font-size: 16px; margin: 24px 0 8px; }
        .content ul, .content ol { padding-left: 24px; margin: 12px 0; }
        .content li { margin-bottom: 8px; }
        .content blockquote {
            border-left: 3px solid #d2d2d7; margin: 16px 0;
            padding: 8px 16px; color: #6e6e73; font-style: italic;
        }
        .content pre {
            font-size: 14px; background: #f5f5f7; border-radius: 8px;
            padding: 14px; overflow-x: auto; line-height: 1.5;
        }
        .content code { font-size: 14px; background: #f5f5f7; padding: 2px 6px; border-radius: 4px; }
        .content pre code { background: none; padding: 0; }
        .content table { border-collapse: collapse; width: 100%; margin: 16px 0; }
        .content th, .content td { border: 1px solid #d2d2d7; padding: 8px 12px; text-align: left; font-size: 14px; }
        .content figure { margin: 16px 0; }
        .content figcaption { font-size: 13px; color: #86868b; text-align: center; margin-top: 6px; }
        .content a { color: #0066cc; text-decoration: none; }
        .content a:hover { text-decoration: underline; }
        .content video, .content iframe { max-width: 100%; }
        </style>
        </head>
        <body>
            <h1>\(title)</h1>
            <div class="meta">\(escapeHTML(sourceName))\(byline)　\(escapeHTML(dateStr))</div>
            <hr>
            <div class="content">\(extracted.content)</div>
        </body>
        </html>
        """
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - Reader WebView

#if os(macOS)
struct ReaderWebView: NSViewRepresentable {
    let html: String
    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }
    func updateNSView(_ webView: WKWebView, context: Context) {}
}

struct OriginalPageWebView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.load(URLRequest(url: url))
        return webView
    }
    func updateNSView(_ webView: WKWebView, context: Context) {}
}
#else
struct ReaderWebView: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}

struct OriginalPageWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.load(URLRequest(url: url))
        return webView
    }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}
#endif

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

