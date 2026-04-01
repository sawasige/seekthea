import Foundation
import WebKit

/// Readability.js（Mozilla）をWKWebViewに注入して記事を抽出する
/// Firefox/Safariのリーダーモードと同じアルゴリズム
@MainActor
class ReadabilityExtractor: NSObject, WKNavigationDelegate {

    struct Article {
        let title: String
        let content: String   // クリーンなHTML（画像・装飾付き）
        let textContent: String // プレーンテキスト（AI用）
        let excerpt: String   // 概要
        let byline: String?   // 著者
        let siteName: String?
    }

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Article?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var readabilityJS: String?

    /// URLから記事を抽出
    func extract(from url: URL) async -> Article? {
        // Readability.jsを読み込み
        if readabilityJS == nil {
            readabilityJS = loadReadabilityJS()
        }
        guard readabilityJS != nil else { return nil }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation

            let config = WKWebViewConfiguration()
            // ページ読み込み完了後にReadability.jsを注入するスクリプト
            let extractionScript = WKUserScript(
                source: buildExtractionScript(),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(extractionScript)

            // 結果を受け取るメッセージハンドラ
            config.userContentController.add(self, name: "readabilityResult")

            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
            wv.navigationDelegate = self
            wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
            self.webView = wv

            let request = URLRequest(url: url, timeoutInterval: 15)
            wv.load(request)

            // タイムアウト
            timeoutTask = Task {
                try? await Task.sleep(for: .seconds(8))
                self.finish(nil)
            }
        }
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // ページ読み込み完了 → 少し待ってReadabilityを実行
        // （遅延ロードコンテンツの完了を待つ）
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            self.runReadability()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }

    // MARK: - Private

    private func loadReadabilityJS() -> String? {
        guard let url = Bundle.main.url(forResource: "Readability", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return js
    }

    private func buildExtractionScript() -> String {
        // Readability.jsを注入 + parse実行 + 結果をネイティブに送信
        guard let js = readabilityJS else { return "" }
        return """
        \(js)

        function __seekthea_extract() {
            try {
                var documentClone = document.cloneNode(true);
                var reader = new Readability(documentClone);
                var article = reader.parse();
                if (article) {
                    window.webkit.messageHandlers.readabilityResult.postMessage({
                        success: true,
                        title: article.title || '',
                        content: article.content || '',
                        textContent: article.textContent || '',
                        excerpt: article.excerpt || '',
                        byline: article.byline || '',
                        siteName: article.siteName || ''
                    });
                } else {
                    window.webkit.messageHandlers.readabilityResult.postMessage({
                        success: false
                    });
                }
            } catch(e) {
                window.webkit.messageHandlers.readabilityResult.postMessage({
                    success: false,
                    error: e.toString()
                });
            }
        }
        """
    }

    private func runReadability() {
        webView?.evaluateJavaScript("__seekthea_extract()") { _, error in
            if error != nil {
                Task { @MainActor in self.finish(nil) }
            }
        }
    }

    private func finish(_ article: Article?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let config = webView?.configuration {
            config.userContentController.removeScriptMessageHandler(forName: "readabilityResult")
        }
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        continuation?.resume(returning: article)
        continuation = nil
    }
}

// MARK: - WKScriptMessageHandler

extension ReadabilityExtractor: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        let messageBody = message.body
        Task { @MainActor in
            guard let dict = messageBody as? [String: Any] else {
                self.finish(nil)
                return
            }

            let success = dict["success"] as? Bool ?? false
            guard success else {
                self.finish(nil)
                return
            }

            let article = Article(
                title: dict["title"] as? String ?? "",
                content: dict["content"] as? String ?? "",
                textContent: dict["textContent"] as? String ?? "",
                excerpt: dict["excerpt"] as? String ?? "",
                byline: (dict["byline"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                siteName: (dict["siteName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            )

            if article.textContent.count < 100 || self.looksLikeConsentPage(article.textContent) {
                self.finish(nil)
            } else {
                self.finish(article)
            }
        }
    }

    private func looksLikeConsentPage(_ text: String) -> Bool {
        let keywords = [
            "ご利用意向の確認", "受信契約を締結", "利用規約に同意",
            "cookieの使用に同意", "チェックをすると次に進めます",
            "ご契約の手続きをお願い",
        ]
        return keywords.contains { text.contains($0) }
    }
}
