import SwiftUI
import SwiftData
import WebKit

// MARK: - 表示モード

private enum DetailViewMode: String, CaseIterable {
    case reader = "リーダー"
    case aiSummary = "AI要約"
    case web = "Web"
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
        VStack(spacing: 0) {
            // モード切り替えPicker（リーダー抽出成功時のみ）
            if extractedArticle != nil {
                Picker("表示モード", selection: $viewMode) {
                    ForEach(DetailViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            // コンテンツ
            ZStack {
                if isLoading {
                    ProgressView("記事を読み込み中...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let extracted = extractedArticle {
                    switch viewMode {
                    case .reader:
                        ReaderView(article: article, extracted: extracted)
                    case .aiSummary:
                        AISummaryView(article: article, isAIProcessing: isAIProcessing)
                    case .web:
                        OriginalPageWebView(url: article.articleURL)
                    }
                } else {
                    OriginalPageWebView(url: article.articleURL)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(article.source?.name ?? "記事")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
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

// MARK: - AI要約ビュー（SwiftUIネイティブ）

private struct AISummaryView: View {
    let article: Article
    var isAIProcessing: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // タイトル
                Text(article.title)
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)

                // メタ情報
                HStack(spacing: 8) {
                    if let sourceName = article.source?.name {
                        Text(sourceName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let date = article.publishedAt {
                        Text(date, style: .date)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // AI要約
                if let summary = article.summary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("AI要約", systemImage: "sparkles")
                            .font(.headline)
                            .foregroundStyle(.blue)

                        Text(LocalizedStringKey(formatMarkdown(summary)))
                            .font(.body)
                            .lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if isAIProcessing {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("AI要約を生成中...", systemImage: "sparkles")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        ShimmerView()
                            .frame(height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } else {
                    Text("AI要約はまだ生成されていません")
                        .foregroundStyle(.secondary)
                }

                // キーワード
                if !article.keywords.isEmpty {
                    Divider()
                    FlowLayout(spacing: 6) {
                        ForEach(article.keywords, id: \.self) { keyword in
                            Text(keyword)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.blue.opacity(0.1))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }
                    }
                }

                // カテゴリ
                if !article.categories.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(article.categories, id: \.self) { cat in
                            Text(cat)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.orange.opacity(0.1))
                                .foregroundStyle(.orange)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func formatMarkdown(_ text: String) -> String {
        // Markdownをそのまま渡す（LocalizedStringKeyがMarkdown解釈する）
        text
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

// MARK: - Reader View (抽出成功時の表示)

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
