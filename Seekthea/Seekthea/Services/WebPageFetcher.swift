import Foundation
import WebKit

/// WKWebViewでページをレンダリングしてからHTMLを取得する
/// JavaScript実行後のDOMを取得できるため、Cookie同意画面やJS描画サイトに対応
@MainActor
class WebPageFetcher: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String?, Never>?
    private var timeoutTask: Task<Void, Never>?

    /// URLからレンダリング済みHTMLを取得
    func fetch(url: URL) async -> String? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation

            let config = WKWebViewConfiguration()
            // Cookie同意を自動で閉じるためのUserScript
            let dismissScript = WKUserScript(
                source: Self.consentDismissJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(dismissScript)

            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
            wv.navigationDelegate = self
            wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
            self.webView = wv

            let request = URLRequest(url: url, timeoutInterval: 15)
            wv.load(request)

            // タイムアウト: 6秒
            timeoutTask = Task {
                try? await Task.sleep(for: .seconds(6))
                self.finish()
            }
        }
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // ページ読み込み完了後、少し待ってからHTMLを取得
        // （JS描画の完了を待つ）
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.8))
            self.extractHTML()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish() }
    }

    // MARK: - Private

    private func extractHTML() {
        webView?.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
            Task { @MainActor in
                let html = result as? String
                self?.finish(html: html)
            }
        }
    }

    private func finish(html: String? = nil) {
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        continuation?.resume(returning: html)
        continuation = nil
    }

    // MARK: - Cookie同意自動dismissスクリプト

    private static let consentDismissJS = """
    (function() {
        // 一般的な同意ボタンのセレクタ
        var selectors = [
            // 同意・承諾ボタン
            'button[class*="consent"]',
            'button[class*="accept"]',
            'button[class*="agree"]',
            'a[class*="consent"]',
            'a[class*="accept"]',
            '[id*="consent"] button',
            '[id*="cookie"] button',
            '[class*="cookie-banner"] button',
            '[class*="cookie-consent"] button',
            // 日本語サイト
            'button:has(> span:contains("同意"))',
            'a:contains("同意する")',
            'a:contains("承諾")',
            'button:contains("同意")',
            'button:contains("OK")',
            'button:contains("Accept")',
            'button:contains("I agree")',
            'button:contains("Accept all")',
            'button:contains("すべて許可")',
        ];

        function clickConsent() {
            for (var i = 0; i < selectors.length; i++) {
                try {
                    var els = document.querySelectorAll(selectors[i]);
                    for (var j = 0; j < els.length; j++) {
                        if (els[j].offsetParent !== null) {
                            els[j].click();
                            return true;
                        }
                    }
                } catch(e) {}
            }

            // テキスト内容で探す
            var buttons = document.querySelectorAll('button, a[role="button"]');
            var keywords = ['同意', '承諾', 'Accept', 'Agree', 'OK', 'すべて許可', 'Accept all', 'Consent'];
            for (var i = 0; i < buttons.length; i++) {
                var text = buttons[i].textContent.trim();
                for (var k = 0; k < keywords.length; k++) {
                    if (text === keywords[k] || text.indexOf(keywords[k]) !== -1) {
                        if (buttons[i].offsetParent !== null) {
                            buttons[i].click();
                            return true;
                        }
                    }
                }
            }
            return false;
        }

        // すぐ試行 + 遅延試行（遅延表示のバナー対策）
        clickConsent();
        setTimeout(clickConsent, 500);
        setTimeout(clickConsent, 1500);

        // Cookie同意のオーバーレイを強制非表示
        var overlaySelectors = [
            '[class*="consent"]', '[class*="cookie-banner"]',
            '[class*="cookie-wall"]', '[id*="consent"]',
            '[class*="gdpr"]', '[class*="privacy-banner"]',
        ];
        setTimeout(function() {
            for (var i = 0; i < overlaySelectors.length; i++) {
                try {
                    var els = document.querySelectorAll(overlaySelectors[i]);
                    for (var j = 0; j < els.length; j++) {
                        els[j].style.display = 'none';
                    }
                } catch(e) {}
            }
            // bodyのoverflow:hiddenを解除（スクロールロック解除）
            document.body.style.overflow = 'auto';
        }, 2000);
    })();
    """
}
