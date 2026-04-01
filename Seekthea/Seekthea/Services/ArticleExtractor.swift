import Foundation
import SwiftSoup

/// 記事URLからHTML本文を抽出する（Readabilityアルゴリズム）
struct ArticleExtractor {

    struct ExtractionResult {
        let plainText: String
        let contentHTML: String
    }

    @MainActor
    static func extract(from url: URL) async -> ExtractionResult? {
        guard let html = await fetchHTML(from: url) else { return nil }
        guard let result = extractFromHTML(html, baseURL: url),
              isValidContent(result.plainText) else { return nil }
        return result
    }

    @MainActor
    static func extractPlainText(from url: URL) async -> String? {
        guard let html = await fetchHTML(from: url) else { return nil }
        guard let text = extractBody(from: html),
              isValidContent(text) else { return nil }
        return text
    }

    static func extractBody(from html: String) -> String? {
        guard let doc = try? SwiftSoup.parse(html) else { return nil }
        stripUnwanted(from: doc)
        guard let content = findContentElement(in: doc) else { return nil }
        pruneNoiseChildren(content)
        return plainText(from: content)
    }

    static func extractFromHTML(_ html: String, baseURL: URL) -> ExtractionResult? {
        guard let doc = try? SwiftSoup.parse(html) else { return nil }
        try? doc.setBaseUri(baseURL.absoluteString)

        stripUnwanted(from: doc)

        guard let content = findContentElement(in: doc) else { return nil }

        pruneNoiseChildren(content)
        resolveImages(in: content, baseURL: baseURL)
        stripAttributes(content)

        guard let text = plainText(from: content),
              let html = try? content.html() else { return nil }

        return ExtractionResult(plainText: text, contentHTML: html)
    }

    // MARK: - 1. タグレベルの一括除去

    private static func stripUnwanted(from doc: Document) {
        // 確実にノイズなタグ
        let tags = [
            "script", "style", "noscript", "iframe", "svg", "canvas",
            "form", "input", "select", "textarea", "button",
            "nav", "footer", "aside", "template",
        ]
        for tag in tags {
            _ = try? doc.select(tag).remove()
        }

        // セレクタベースのノイズ（広告・UI・SNS等）
        let selectors = [
            // 構造
            "[role=navigation]", "[role=banner]", "[role=complementary]", "[role=contentinfo]",
            "[aria-hidden=true]",
            // 広告
            ".ad", ".ads", ".adsbygoogle", ".advertisement", ".ad-container",
            "[id*=google_ads]", "[id*=sponsor]", "[class*=sponsor]",
            // ナビ・メニュー
            ".sidebar", ".navigation", ".menu", ".breadcrumb", ".breadcrumbs",
            ".site-header", ".site-footer", ".global-header", ".global-footer",
            // SNS・共有
            ".social-share", ".share-buttons", ".share-bar", ".sns-share",
            ".social-links", ".twitter-tweet", ".instagram-media",
            "[class*=share]",
            // コメント
            ".comments", "#comments", ".comment-section", "#disqus_thread",
            // 関連記事
            ".related-articles", ".related-posts", ".recommend",
            "[class*=related]", "[class*=ranking]", "[class*=popular]",
            // UI要素
            ".cookie-banner", ".popup", ".modal", ".overlay", ".alert-banner",
            ".newsletter", ".subscribe", ".signup",
            // 日本語サイト特有
            "[class*=pickup]", "[class*=follow]", "[class*=author-profile]",
            "[class*=tag-list]", "[class*=pager]", "[class*=pagination]",
            ".pr-label", ".sponsored",
        ]
        for selector in selectors {
            _ = try? doc.select(selector).remove()
        }
    }

    // MARK: - 2. コンテンツ要素の検出

    private static func findContentElement(in doc: Document) -> Element? {
        // 候補をスコアリングして最良を返す
        var candidates: [(element: Element, score: Int)] = []

        // <article>タグ
        if let articles = try? doc.select("article") {
            for article in articles {
                let s = scoreElement(article)
                if s > 0 { candidates.append((article, s)) }
            }
        }

        // よくあるセレクタ
        let contentSelectors = [
            "[role=main]", "main",
            "#main-content", "#main", "#content", "#article",
            ".main-content", ".article-body", ".entry-content", ".post-content",
            ".article__body", ".story-body", ".content-body", ".article-text",
            "#article-body", ".post-body", ".article_body", ".newsarticle",
            ".article-detail", ".article-main", ".news-body", ".post-detail",
            // 日本語サイト
            ".article-content", ".entry-body", ".post-entry",
            "#main_content", "#article_body",
        ]
        for selector in contentSelectors {
            if let el = try? doc.select(selector).first() {
                let s = scoreElement(el)
                if s > 0 { candidates.append((el, s)) }
            }
        }

        // 全divをスコアリング
        if let divs = try? doc.select("div, section") {
            for div in divs {
                let s = scoreElement(div)
                if s > 50 { candidates.append((div, s)) }
            }
        }

        // 最高スコアの要素を返す
        return candidates.max(by: { $0.score < $1.score })?.element
    }

    /// Readabilityスコア: テキスト密度が高く、リンク密度が低い要素が高スコア
    private static func scoreElement(_ element: Element) -> Int {
        let text = (try? element.text()) ?? ""
        let textLen = text.count
        guard textLen >= 80 else { return 0 }

        let pCount = (try? element.select("p").size()) ?? 0
        let imgCount = (try? element.select("img").size()) ?? 0

        // リンクテキストの割合（高い＝ナビゲーション的）
        let linkText = (try? element.select("a").text().count) ?? 0
        let linkDensity = textLen > 0 ? Double(linkText) / Double(textLen) : 1.0

        // リンク密度が高すぎる → ナビゲーション
        if linkDensity > 0.5 { return 0 }

        var score = textLen / 10         // テキスト量
        score += pCount * 10             // <p>が多い＝記事
        score += imgCount * 5            // 画像も記事の一部
        score -= Int(linkDensity * 200)  // リンク密度のペナルティ

        // class/idにarticle, content, post等が含まれればボーナス
        let classId = ((try? element.className()) ?? "") + (element.id())
        let positivePatterns = ["article", "content", "post", "entry", "body", "text", "main", "news", "story"]
        let negativePatterns = ["sidebar", "comment", "footer", "header", "menu", "nav", "related", "widget", "ad"]
        for p in positivePatterns where classId.localizedCaseInsensitiveContains(p) { score += 20 }
        for p in negativePatterns where classId.localizedCaseInsensitiveContains(p) { score -= 40 }

        return score
    }

    // MARK: - 3. コンテンツ内部のノイズ子要素を刈り取る

    private static func pruneNoiseChildren(_ element: Element) {
        let children = element.children()

        // 逆順で処理（削除してもインデックスがずれない）
        for child in children.reversed() {
            let tag = child.tagName()

            // 本文要素はそのまま残す
            if ["p", "h1", "h2", "h3", "h4", "h5", "h6",
                "blockquote", "pre", "code", "table",
                "ul", "ol", "dl", "figure", "picture", "video", "audio"].contains(tag) {
                // ただしリンクだらけの<p>やリストは除去
                if isLinkHeavy(child) {
                    try? child.remove()
                }
                continue
            }

            // <img>は残す
            if tag == "img" { continue }

            // <div>, <section>, <span>等 → スコアで判定
            let text = (try? child.text()) ?? ""
            let textLen = text.count

            // テキストが短すぎる
            if textLen < 30 {
                // ただし画像を含む場合は残す
                let hasImg = ((try? child.select("img").size()) ?? 0) > 0
                if !hasImg {
                    try? child.remove()
                    continue
                }
            }

            // リンク密度が高い
            if isLinkHeavy(child) {
                try? child.remove()
                continue
            }

            // 再帰的に子要素もpruneする
            pruneNoiseChildren(child)
        }
    }

    /// リンクテキストが全体の50%以上を占めるか
    private static func isLinkHeavy(_ element: Element) -> Bool {
        let totalText = ((try? element.text()) ?? "").count
        guard totalText > 0 else { return false }
        let linkText = ((try? element.select("a").text()) ?? "").count
        return Double(linkText) / Double(totalText) > 0.5
    }

    // MARK: - 4. 不要な属性の除去（表示を軽くする）

    private static func stripAttributes(_ element: Element) {
        let keepAttrs: Set<String> = ["src", "href", "alt", "title", "colspan", "rowspan"]

        if let allElements = try? element.select("*") {
            for el in allElements {
                guard let attrs = el.getAttributes() else { continue }
                for attr in attrs {
                    if !keepAttrs.contains(attr.getKey()) {
                        _ = try? el.removeAttr(attr.getKey())
                    }
                }
            }
        }
    }

    // MARK: - 5. 画像URL解決

    private static func resolveImages(in element: Element, baseURL: URL) {
        guard let images = try? element.select("img") else { return }
        for img in images {
            let lazySrc = (try? img.attr("data-src"))
                ?? (try? img.attr("data-lazy-src"))
                ?? (try? img.attr("data-original"))
            let src = lazySrc ?? (try? img.attr("src")) ?? ""

            if !src.isEmpty, let resolved = URL(string: src, relativeTo: baseURL)?.absoluteString {
                _ = try? img.attr("src", resolved)
            }

            // lazy属性はstripAttributesで消えるので個別処理不要
        }
    }

    // MARK: - 6. HTML取得（URLSession優先、同意画面検出時のみWKWebView）

    @MainActor
    private static func fetchHTML(from url: URL) async -> String? {
        // まずURLSessionで高速取得
        if let html = await fetchWithURLSession(from: url) {
            // 同意画面っぽくなければそのまま使う
            if !looksLikeConsentPage(html) {
                return html
            }
        }

        // 同意画面 or 取得失敗 → WKWebViewでJS実行後のDOMを取得
        let fetcher = WebPageFetcher()
        return await fetcher.fetch(url: url)
    }

    private static func fetchWithURLSession(from url: URL) async -> String? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .japaneseEUC)
            ?? String(data: data, encoding: .shiftJIS)
    }

    /// 同意画面・Cookie壁かどうかを簡易判定
    private static func looksLikeConsentPage(_ html: String) -> Bool {
        let lower = html.lowercased()
        let text = (try? SwiftSoup.parse(html).body()?.text()) ?? ""

        // HTML属性/クラス名で検出
        let htmlKeywords = [
            "cookie-consent", "cookie-wall", "cookie-banner",
            "consent-manager", "gdpr", "privacy-wall",
        ]
        let htmlHits = htmlKeywords.filter { lower.contains($0) }.count

        // 表示テキストで検出（日本語サイト）
        let textKeywords = [
            "ご利用意向の確認", "受信契約", "利用規約に同意",
            "cookieの使用に同意", "プライバシーポリシーに同意",
            "ご契約の手続き", "チェックをすると次に進めます",
        ]
        let textHits = textKeywords.filter { text.contains($0) }.count

        if textHits >= 1 { return true }
        if htmlHits >= 2 { return true }

        // 本文がほぼ空なのにHTMLはある → JS描画サイト
        if text.count < 200 && html.count > 5000 { return true }

        return false
    }

    /// 抽出済みコンテンツが同意/壁ページのテキストでないか検証
    static func isValidContent(_ text: String) -> Bool {
        let invalidKeywords = [
            "ご利用意向の確認", "受信契約を締結", "利用規約に同意",
            "cookieの使用に同意", "チェックをすると次に進めます",
            "ご契約の手続きをお願い", "プライバシーポリシーに同意",
        ]
        for keyword in invalidKeywords {
            if text.contains(keyword) { return false }
        }
        // テキストが短すぎる
        if text.count < 80 { return false }
        return true
    }

    // MARK: - 7. プレーンテキスト

    private static func plainText(from element: Element) -> String? {
        guard let text = try? element.text() else { return nil }
        let cleaned = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return cleaned.isEmpty ? nil : String(cleaned.prefix(3000))
    }
}
