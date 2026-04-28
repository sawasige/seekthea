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
    private var onProgress: ((String) -> Void)?
    /// 「本文を見る」等で1段だけ follow したかを記録。連鎖 follow を防ぐ。
    private var hasFollowed: Bool = false

    /// URLから記事を抽出
    func extract(from url: URL, onProgress: ((String) -> Void)? = nil) async -> Article? {
        // Readability.jsを読み込み
        if readabilityJS == nil {
            readabilityJS = loadReadabilityJS()
        }
        guard readabilityJS != nil else { return nil }

        self.onProgress = onProgress
        self.hasFollowed = false
        onProgress?("記事ページを取得中...")

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
            self.onProgress?("本文を抽出中...")
            try? await Task.sleep(for: .milliseconds(800))
            self.runReadability()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("[Reader] Navigation failed: \(error.localizedDescription)")
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("[Reader] Provisional navigation failed: \(error.localizedDescription)")
        Task { @MainActor in self.finish(nil) }
    }

    // MARK: - Private

    private func loadReadabilityJS() -> String? {
        guard let url = Bundle.main.url(forResource: "Readability", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else {
            print("[Reader] Readability.js not found in bundle")
            return nil
        }
        return js
    }

    private func buildExtractionScript() -> String {
        // Readability.jsを注入 + DOM 前処理 + parse実行 + 結果をネイティブに送信
        guard let js = readabilityJS else { return "" }
        return """
        \(js)

        // Readability に渡す前に明らかなノイズ要素を取り除く。
        // サイドバー / ナビ / 関連記事 / 広告 / シェアボタンなどが本文として
        // 誤判定されるのを防ぐ。<header> は記事ヘッダにも使われるので除外しない。
        function __seekthea_cleanDOM(doc) {
            var selectors = [
                'aside', 'nav', 'footer',
                '[role="complementary"]', '[role="navigation"]', '[role="banner"]', '[role="contentinfo"]',
                '.sidebar', '.side-bar', '.side',
                '.related', '.related-articles', '.recommend', '.recommended', '.recommendation',
                '.ranking', '.popular', '.trending',
                '.ad', '.ads', '.advertisement', '.adsbygoogle', '[class*="-ad"]', '[id^="ad-"]',
                '.share', '.shares', '.social', '.sns',
                '.comments', '.comment-list',
                '.breadcrumb', '.breadcrumbs',
                '.newsletter', '.subscribe'
            ];
            try {
                doc.querySelectorAll(selectors.join(',')).forEach(function(el) {
                    if (el.parentNode) el.parentNode.removeChild(el);
                });
            } catch(e) { /* セレクタ失敗は無視して続行 */ }
        }

        // 「本文を見る」等の誘導リンクを探す。
        // 同一ホスト + アンカーテキスト whitelist + トラッカー除外で誤爆を防ぐ。
        function __seekthea_findFollowLinkIn(links) {
            var FOLLOW_PATTERNS = [
                '本文を見る', '本文を読む', '本文表示', '本文へ',
                '全文を読む', '全文表示', '全文を見る', '記事全文',
                '続きを読む', '記事を読む', '記事の続き', '記事の続きを読む',
                'もっと読む', '元記事を読む', '詳細を読む', '詳細はこちら'
            ];
            var TRACKER_PATTERN = /[?&](utm_|gclid=|fbclid=|affid=|mc_|s_kwcid=)/;
            var origin = location.hostname;

            for (var i = 0; i < links.length; i++) {
                var link = links[i];
                var text = (link.textContent || '').trim();
                var href = link.href;
                if (!href || href.indexOf('http') !== 0) continue;
                if (href === location.href) continue;

                var matched = false;
                for (var j = 0; j < FOLLOW_PATTERNS.length; j++) {
                    if (text.indexOf(FOLLOW_PATTERNS[j]) !== -1) { matched = true; break; }
                }
                if (!matched) continue;

                try {
                    var url = new URL(href);
                    if (url.hostname !== origin) continue;
                } catch(e) { continue; }

                if (TRACKER_PATTERN.test(href)) continue;

                return href;
            }
            return null;
        }

        // 抽出本文 → ダメなら main/article 領域から follow リンクを探す。
        // Readability が CTA ボタンを本文外として除外することがあるため2段で探す。
        function __seekthea_findFollowLink(articleHTML) {
            try {
                var container = document.createElement('div');
                container.innerHTML = articleHTML;
                var inExtracted = __seekthea_findFollowLinkIn(container.querySelectorAll('a[href]'));
                if (inExtracted) return inExtracted;
            } catch(e) { /* ignore */ }

            try {
                var roots = document.querySelectorAll('main, article, [role="main"]');
                for (var i = 0; i < roots.length; i++) {
                    var found = __seekthea_findFollowLinkIn(roots[i].querySelectorAll('a[href]'));
                    if (found) return found;
                }
            } catch(e) { /* ignore */ }

            return null;
        }

        function __seekthea_extract(alreadyFollowed) {
            try {
                var documentClone = document.cloneNode(true);
                __seekthea_cleanDOM(documentClone);
                var reader = new Readability(documentClone);
                var article = reader.parse();

                // 本文ページへの誘導リンク（「記事全文を読む」等）が見つかれば redirect 要求。
                // 本文長さは見ない: 要約ページが要約だけで長いケース (Yahoo など) を取りこぼさないため。
                // 同一ホスト + アンカーテキスト whitelist + トラッカー除外で誤爆を防いでいる。
                // 既に1段 follow 済みの場合は再 follow しない (連鎖防止)。
                if (article && !alreadyFollowed) {
                    var followURL = __seekthea_findFollowLink(article.content);
                    if (followURL) {
                        window.webkit.messageHandlers.readabilityResult.postMessage({
                            success: false,
                            redirect: followURL
                        });
                        return;
                    }
                }

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
        let alreadyFollowed = hasFollowed ? "true" : "false"
        webView?.evaluateJavaScript("__seekthea_extract(\(alreadyFollowed))") { _, error in
            if error != nil {
                Task { @MainActor in self.finish(nil) }
            }
        }
    }

    private func finish(_ article: Article?) {
        guard continuation != nil else { return }  // 2回目以降は無視
        timeoutTask?.cancel()
        timeoutTask = nil
        if let config = webView?.configuration {
            config.userContentController.removeScriptMessageHandler(forName: "readabilityResult")
        }
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        onProgress = nil
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
                print("[Reader] Message body is not a dictionary")
                self.finish(nil)
                return
            }

            // 「本文を見る」誘導の follow 要求 (1段だけ許可、無限ループ防止)
            if let redirectStr = dict["redirect"] as? String,
               let redirectURL = URL(string: redirectStr),
               !self.hasFollowed,
               redirectURL != self.webView?.url {
                self.hasFollowed = true
                self.onProgress?("本文ページへ移動中...")
                self.timeoutTask?.cancel()
                self.timeoutTask = Task {
                    try? await Task.sleep(for: .seconds(8))
                    await MainActor.run { self.finish(nil) }
                }
                self.webView?.load(URLRequest(url: redirectURL, timeoutInterval: 15))
                return
            }

            let success = dict["success"] as? Bool ?? false
            guard success else {
                let error = dict["error"] as? String ?? "unknown"
                print("[Reader] Readability.js failed: \(error)")
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

            if article.textContent.count < 100 {
                self.finish(nil)
            } else if self.looksLikeConsentPage(article.textContent) {
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
