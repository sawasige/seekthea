# Seekthea — パーソナルトレンドアグリゲーター

## プロジェクト概要

ニュースサイト・ソーシャルメディア・テックコミュニティからRSSでトレンドを収集し、Apple Intelligenceでオンデバイス要約・カテゴリ分類を行うiOSアプリ。Google News RSSをソース発見エンジンとして活用し、新しいソースを自動的に提案する。サーバー不要、APIキー不要、月額コストゼロ。

> **名前の由来**: Seek（探し求める）+ Thea（ギリシャ神話の視覚の女神テイア / ギリシャ語で「眺め・視界」）。ウェブ全体のトレンドを見通して、探し出すアプリ。

## システム構成

```
[Google News RSS] ──→ Source Discovery
                          ↓
[RSS Feeds] ──→ FeedKit ──→ Content Enrichment ──→ Apple Intelligence ──→ SwiftData ──→ SwiftUI
                           (LPMetadataProvider)    (on-device LLM)        (local DB)
```

### 技術スタック

| レイヤー | 技術 | 備考 |
|----------|------|------|
| RSS取得・パース | FeedKit | Swift製、RSS/Atom/JSON Feed対応 |
| コンテンツ補完 | LPMetadataProvider | OGP画像・説明文・faviconを自動取得 |
| AI要約・分類 | Foundation Models framework | iOS 26+、オンデバイス、無料 |
| DB＆同期 | SwiftData + CloudKit | 全デバイス自動同期（Host in CloudKit = ON） |
| UI | SwiftUI | マルチプラットフォーム対応 |
| ソース追加 | Share Extension | Safariから直接追加 |
| プリセット配信 | GitHub Pages | 静的JSON、無料 |

### 動作要件

- **対応プラットフォーム**: iPhone / iPad / Mac（Multiplatform App）
- iPhone 15 Pro 以降（Apple Intelligence対応デバイス）
- iOS 26+ / iPadOS 26+ / macOS 26+（Foundation Models framework）
- iCloudアカウント（CloudKit同期に必要）
- AI非対応デバイスでは要約・分類なしのフォールバック動作

### CloudKit同期の対象

| 同期する | 同期しない |
|----------|------------|
| お気に入り（isFavorite） | RSSフィードのキャッシュデータ |
| 既読状態（isRead） | エンリッチメント中間データ |
| ソース設定（追加/削除/ON/OFF） | AI処理のキュー状態 |
| AI要約結果 | — |
| 発見ドメインの拒否リスト | — |

---

## Phase 1: RSSフィード取得＆データ保存

### データモデル（SwiftData + CloudKit）

> **CloudKit対応**: Host in CloudKit = ON。お気に入り・既読状態・ソース設定が全デバイス（iPhone/iPad/Mac）で自動同期。以下のCloudKit制約に注意:
> - `@Attribute(.unique)` は使用不可 → 重複チェックはコード側で実装
> - 全プロパティにデフォルト値が必要 → CloudKitのマージ解決に必要
> - 大きなDataプロパティはiCloud容量に影響 → faviconは軽量に保つ
> - マルチデバイスで同時編集時はlast-write-wins

```swift
enum SourceType: String, Codable {
    case news = "ニュース"           // NHK, ITmedia, GIGAZINE etc.
    case social = "ソーシャル"        // Reddit, はてブ, Bluesky etc.
    case tech = "テック"             // Hacker News, Zenn, Qiita etc.
    case discovery = "発見"          // Google News（ソース発見用）
}

@Model
class Source {
    var id: UUID = UUID()
    var name: String = ""
    var feedURL: URL = URL(string: "https://example.com")!
    var siteURL: URL = URL(string: "https://example.com")!
    var sourceType: String = SourceType.news.rawValue  // CloudKit互換のためrawValue保存
    var category: String = ""
    var isActive: Bool = true
    var isPreset: Bool = false
    var addedAt: Date = Date()
    var lastFetchedAt: Date? = nil
    var articleCount: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \Article.source)
    var articles: [Article] = []

    // Computed（CloudKitには保存されない）
    var sourceTypeEnum: SourceType {
        get { SourceType(rawValue: sourceType) ?? .news }
        set { sourceType = newValue.rawValue }
    }
}

@Model
class Article {
    var id: UUID = UUID()
    var title: String = ""
    var articleURL: URL = URL(string: "https://example.com")!
    var leadText: String? = nil
    var imageURL: URL? = nil
    var publishedAt: Date? = nil
    var fetchedAt: Date = Date()

    // Content Enrichment（LPMetadataProvider）
    var ogDescription: String? = nil
    var ogImageURL: URL? = nil
    var siteFaviconData: Data? = nil   // 軽量に保つ（16x16 PNG推奨）
    var isEnriched: Bool = false

    // AI処理結果（デバイスごとに処理、同期される）
    var summary: String? = nil
    var aiCategory: String? = nil
    var keywordsRaw: String = ""       // CloudKit互換: [String]の代わりにカンマ区切りで保存
    var isAIProcessed: Bool = false

    // ユーザー操作（これが同期の主目的）
    var isRead: Bool = false
    var isFavorite: Bool = false

    var source: Source? = nil

    // Computed properties
    var keywords: [String] {
        get { keywordsRaw.isEmpty ? [] : keywordsRaw.components(separatedBy: ",") }
        set { keywordsRaw = newValue.joined(separator: ",") }
    }

    var displayImageURL: URL? {
        imageURL ?? ogImageURL
    }

    var displayDescription: String? {
        summary ?? ogDescription ?? leadText
    }

    var textForAI: String {
        let desc = ogDescription ?? leadText ?? ""
        return "タイトル: \(title)\n内容: \(desc)"
    }
}

@Model
class DiscoveredDomain {
    var domain: String = ""
    var firstSeenAt: Date = Date()
    var lastSeenAt: Date = Date()
    var mentionCount: Int = 0
    var detectedFeedURL: URL? = nil
    var isRejected: Bool = false
    var isSuggested: Bool = false
}
```

### RSS取得フロー

```swift
class FeedFetcher {
    /// アクティブなソースからRSSを取得
    func fetchAll() async {
        let sources = activeSources
        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask {
                    await self.fetchFeed(source)
                }
            }
        }
    }

    /// 個別フィード取得
    func fetchFeed(_ source: Source) async {
        // 1. FeedKitでRSSをパース
        // 2. 既存記事とURL重複チェック
        // 3. 新規記事をSwiftDataに保存
        // 4. source.lastFetchedAt を更新
    }
}
```

### 更新タイミング

- アプリ起動時（前回取得から30分以上経過していたら）
- Pull-to-refresh
- Background App Refresh（BGAppRefreshTask）
  - 最小間隔: 30分
  - 最大取得ソース数: 10（バッテリー考慮）

### 初期プリセットソース

アプリにバンドルするJSON（`preset_sources.json`）:

```json
{
  "news": [
    {
      "name": "NHK News Web",
      "feedURL": "https://www.nhk.or.jp/rss/news/cat0.xml",
      "siteURL": "https://www3.nhk.or.jp/news/",
      "sourceType": "news",
      "category": "総合"
    },
    {
      "name": "GIGAZINE",
      "feedURL": "https://gigazine.net/news/rss_2.0/",
      "siteURL": "https://gigazine.net/",
      "sourceType": "news",
      "category": "テクノロジー"
    },
    {
      "name": "ITmedia NEWS",
      "feedURL": "https://rss.itmedia.co.jp/rss/2.0/news_bursts.xml",
      "siteURL": "https://www.itmedia.co.jp/news/",
      "sourceType": "news",
      "category": "テクノロジー"
    }
  ],
  "social": [
    {
      "name": "はてなブックマーク - 人気",
      "feedURL": "https://b.hatena.ne.jp/hotentry.rss",
      "siteURL": "https://b.hatena.ne.jp/",
      "sourceType": "social",
      "category": "トレンド"
    },
    {
      "name": "Reddit - r/technology",
      "feedURL": "https://www.reddit.com/r/technology/.rss",
      "siteURL": "https://www.reddit.com/r/technology/",
      "sourceType": "social",
      "category": "テクノロジー"
    },
    {
      "name": "Reddit - r/japan",
      "feedURL": "https://www.reddit.com/r/japan/.rss",
      "siteURL": "https://www.reddit.com/r/japan/",
      "sourceType": "social",
      "category": "総合"
    }
  ],
  "tech": [
    {
      "name": "Hacker News - Best",
      "feedURL": "https://hnrss.org/best",
      "siteURL": "https://news.ycombinator.com/",
      "sourceType": "tech",
      "category": "テクノロジー"
    },
    {
      "name": "Zenn - トレンド",
      "feedURL": "https://zenn.dev/feed",
      "siteURL": "https://zenn.dev/",
      "sourceType": "tech",
      "category": "開発"
    },
    {
      "name": "Qiita - トレンド",
      "feedURL": "https://qiita.com/popular-items/feed",
      "siteURL": "https://qiita.com/",
      "sourceType": "tech",
      "category": "開発"
    },
    {
      "name": "Product Hunt",
      "feedURL": "https://www.producthunt.com/feed",
      "siteURL": "https://www.producthunt.com/",
      "sourceType": "tech",
      "category": "プロダクト"
    }
  ]
}
```

> **注意**: RSS URLは実装時に実際のサイトで確認すること。変更されている可能性あり。

---

## Phase 1.5: Content Enrichment — LPMetadataProviderによるコンテンツ補完

### 課題

RSSフィードは記事のヘッドライン（title）と簡素なdescriptionしか含まないことが多く、サムネイル画像がないケースも多い。これではリッチなニュースカードUIを構築できず、AI要約の入力としても情報が不足する。

### 解決策: LinkPresentation framework

iOSの `LPMetadataProvider` を使い、記事URLからOGP（Open Graph Protocol）メタデータを自動取得する。ほぼ100%のニュースサイトがOGPタグを設定しているため、確実にリッチな情報が得られる。

```swift
import LinkPresentation

class ContentEnricher {
    private let metadataProvider = LPMetadataProvider()

    /// 記事のコンテンツをOGPメタデータで補完
    func enrich(_ article: Article) async {
        guard !article.isEnriched else { return }

        do {
            let metadata = try await metadataProvider.startFetchingMetadata(for: article.articleURL)

            // OGP説明文（RSSのdescriptionより充実していることが多い）
            // メタデータには直接descriptionプロパティがないため、
            // URLSessionで記事HTMLを取得し og:description を抽出する
            if let ogDesc = await fetchOGDescription(from: article.articleURL) {
                article.ogDescription = ogDesc
            }

            // OGP画像
            if let imageProvider = metadata.imageProvider {
                let image = try await loadImage(from: imageProvider)
                // 画像URLをキャッシュまたはData保存
                article.ogImageURL = metadata.url  // 必要に応じて画像URLを別途抽出
            }

            // Favicon
            if let iconProvider = metadata.iconProvider {
                let iconData = try await loadImageData(from: iconProvider)
                article.siteFaviconData = iconData
            }

            article.isEnriched = true
        } catch {
            // エンリッチメント失敗は致命的ではない。RSSデータだけで表示を続行
            print("Enrichment failed for \(article.articleURL): \(error)")
            article.isEnriched = true  // リトライ防止
        }
    }

    /// HTMLから og:description を抽出
    private func fetchOGDescription(from url: URL) async -> String? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let html = String(data: data, encoding: .utf8) else { return nil }

        // <meta property="og:description" content="..."> を正規表現で抽出
        let pattern = #"<meta\s+property="og:description"\s+content="([^"]*)"#
        guard let match = html.range(of: pattern, options: .regularExpression) else { return nil }
        // contentの値を抽出して返す
        return extractContent(from: html, match: match)
    }
}
```

### エンリッチメントの優先度制御

すべての記事を即座にエンリッチすると通信量が増えるため、段階的に処理する:

```swift
class EnrichmentQueue {
    /// エンリッチメント優先度
    enum Priority {
        case high    // 画面に表示中の記事
        case medium  // 直近24時間の新着記事
        case low     // それ以外
    }

    /// 画面に表示される記事を優先的にエンリッチ
    func enqueueVisible(_ articles: [Article]) {
        for article in articles where !article.isEnriched {
            enqueue(article, priority: .high)
        }
    }

    /// 新着記事をバックグラウンドでエンリッチ
    func enqueueNew(_ articles: [Article]) {
        for article in articles where !article.isEnriched {
            let priority: Priority = article.fetchedAt > .now.addingTimeInterval(-86400) ? .medium : .low
            enqueue(article, priority: priority)
        }
    }
}
```

### UI表示の段階的リッチ化

```
[Stage 1] RSS取得直後:
  → タイトル + leadText（あれば） + プレースホルダ画像
  → すぐに表示（ユーザーを待たせない）

[Stage 2] エンリッチメント完了後:
  → OGP画像に差し替え（AsyncImageでフェードイン）
  → ogDescription で説明文を更新
  → favicon をソースアイコンとして表示

[Stage 3] AI処理完了後:
  → AI要約に差し替え
  → カテゴリバッジ表示
  → キーワードタグ表示
```

記事カードは `article.displayImageURL` と `article.displayDescription` を使うことで、どのステージでも最もリッチな情報が自動的に表示される。

---

## Phase 2: Apple Intelligence — オンデバイスAI処理

### Foundation Models framework の使用

```swift
import FoundationModels

struct ArticleAnalysis: Codable {
    let category: String    // カテゴリ名
    let summary: String     // 3文以内の要約
    let keywords: [String]  // 最大3つのキーワード
}

class AIProcessor {
    let model = FoundationModel(.onDevice)

    func analyze(article: Article) async throws -> ArticleAnalysis {
        let prompt = """
        以下のニュース記事を分析してください。

        \(article.textForAI)

        以下のカテゴリから1つ選択: テクノロジー, ビジネス, 政治, 社会, スポーツ, エンタメ, サイエンス, ライフ

        JSON形式で回答:
        - category: カテゴリ名
        - summary: 100文字程度の日本語要約（3文以内）
        - keywords: 関連キーワード（最大3つ）
        """

        // Guided Generationで構造化出力
        let result = try await model.generate(
            prompt,
            generating: ArticleAnalysis.self
        )
        return result
    }
}
```

### カテゴリ定義

```swift
enum ContentCategory: String, CaseIterable, Codable {
    case technology = "テクノロジー"   // IT, AI, ガジェット
    case business = "ビジネス"         // 経済, 企業, スタートアップ
    case politics = "政治"             // 国内・国際政治
    case society = "社会"              // 事件, 地域, 教育
    case sports = "スポーツ"
    case entertainment = "エンタメ"    // 芸能, 映画, ゲーム
    case science = "サイエンス"        // 科学, 宇宙, 医療
    case lifestyle = "ライフ"          // 健康, グルメ, 旅行
    case dev = "開発"                  // プログラミング, OSS, ツール
    case product = "プロダクト"        // 新サービス, アプリ, ガジェット
    case trend = "トレンド"            // ソーシャルで話題のもの
}
```

### AI処理の最適化

- エンリッチ済みの場合は `ogDescription`（より詳しい）を使用、未エンリッチならRSSの `leadText` にフォールバック（`article.textForAI` が自動選択）
- バッチ処理: 新規記事をまとめて処理（1記事ずつではなくキューで管理）
- キャッシュ: 1度処理したらSwiftDataに保存。再処理しない
- フォールバック: AI非対応デバイスではカテゴリ = ソースのデフォルト、要約 = `article.displayDescription` をそのまま表示

### AI処理のタイミング

- エンリッチメント完了後にAI処理を実行（より良い入力 → より良い要約）
- エンリッチメントが遅い場合はRSSデータだけでAI処理を先行実行
- 処理中はUI上で shimmer アニメーション表示
- デバイスが低電力モードの場合はスキップ（後でまとめて処理）

---

## Phase 3: ソース自動発見（Google News RSS）

### Google News RSSフィード

```swift
struct GoogleNewsDiscovery {
    // カテゴリ別Google News RSS（日本語）
    static let discoveryFeeds: [(name: String, url: URL)] = [
        ("トップ", URL(string: "https://news.google.com/rss?hl=ja&gl=JP&ceid=JP:ja")!),
        ("テクノロジー", URL(string: "https://news.google.com/rss/topics/CAAqKggKIiRDQkFTRlFvSUwyMHZNRGRqTVhZU0JXcGhMVXBRR2dKS1VDQUFQAQ?hl=ja&gl=JP&ceid=JP:ja")!),
        ("ビジネス", URL(string: "https://news.google.com/rss/topics/CAAqKggKIiRDQkFTRlFvSUwyMHZNRGx6TVdZU0JXcGhMVXBRR2dKS1VDQUFQAQ?hl=ja&gl=JP&ceid=JP:ja")!),
    ]

    /// Google Newsの記事から未知のドメインを抽出
    func discoverNewSources() async {
        for feed in Self.discoveryFeeds {
            let items = await parseFeed(feed.url)
            for item in items {
                let domain = extractDomain(from: item.link)

                // 既知のソース → スキップ
                if isKnownSource(domain) { continue }
                // 拒否済み → スキップ
                if isRejectedDomain(domain) { continue }

                // DiscoveredDomain に記録（出現回数をカウント）
                upsertDiscoveredDomain(domain)
            }
        }

        // 出現回数が閾値を超えたドメインに対してRSS自動検出
        let candidates = getFrequentUnsuggested(threshold: 3)
        for candidate in candidates {
            if let feedURL = await detectRSSFeed(candidate.domain) {
                candidate.detectedFeedURL = feedURL
                // ユーザーに提案
                suggestToUser(candidate)
            }
        }
    }
}
```

### RSS自動検出

```swift
class RSSDetector {
    /// サイトURLからRSSフィードを自動検出
    func detectRSSFeed(from siteURL: URL) async -> URL? {
        // 1. HTMLを取得
        let html = try await fetchHTML(siteURL)

        // 2. <link rel="alternate" type="application/rss+xml"> を探す
        let feedURLs = parseAlternateLinks(html)

        // 3. 見つかった場合、最初のフィードURLを返す
        return feedURLs.first

        // 4. 見つからない場合、よくあるパスを試す
        //    /feed, /rss, /rss.xml, /feed/rss2, /atom.xml
    }
}
```

### 発見フロー全体

1. **自動発見**: Google News RSSを週1回バックグラウンドでパース
2. **出現カウント**: 未知ドメインの出現回数を DiscoveredDomain に蓄積
3. **閾値判定**: 1週間で3回以上出現したドメインを候補にする
4. **RSS検出**: 候補サイトのHTMLからRSSフィードを自動検出
5. **ユーザー提案**: 「〇〇が新しいソースとして見つかりました」通知
6. **承認 or 拒否**: ユーザーが「追加」→ Source登録 / 「スキップ」→ isRejected = true

### 記事内リンクからの発見（補助）

収集済み記事のleadText内に含まれる外部リンクからもドメインを抽出。Google News発見と同じフローで DiscoveredDomain に蓄積する。

---

## Phase 4: Share Extension（手動ソース追加）

### 構成

```
Seekthea/
├── Seekthea (main app)
└── SeektheaShareExtension (share extension)
    └── ShareViewController.swift
```

### 動作フロー

1. Safariで気になるニュースサイトを閲覧
2. 共有ボタン → Seekthea を選択
3. Share Extension がURLを受信
4. RSSDetector でフィードを自動検出
5. 検出結果をApp Groupの共有コンテナに保存
6. メインアプリ起動時に読み込み → ソース追加確認

### App Group 設定

```swift
// App Group ID: group.com.yourname.seekthea
let sharedDefaults = UserDefaults(suiteName: "group.com.yourname.seekthea")

// Share Extensionが書き込み
sharedDefaults?.set(pendingSources, forKey: "pendingSources")

// メインアプリが読み取り
let pending = sharedDefaults?.array(forKey: "pendingSources")
```

---

## Phase 5: Remote Preset（プリセット更新）

### GitHub Pages での配信

リポジトリ: `github.com/yourname/seekthea-presets`

```
seekthea-presets/
└── sources.json    ← アプリが定期的にfetch
```

### sources.json の構造

```json
{
  "version": 2,
  "updated_at": "2026-04-01T00:00:00Z",
  "sources": [
    {
      "name": "NHK News Web",
      "feedURL": "https://www.nhk.or.jp/rss/news/cat0.xml",
      "siteURL": "https://www3.nhk.or.jp/news/",
      "category": "総合"
    }
  ]
}
```

### 更新チェック

- アプリ起動時（最終チェックから24時間以上経過していたら）
- version番号で差分検知
- 新しいソースがあればユーザーに提案（自動追加はしない）

---

## Phase 6: iOSアプリ UI（SwiftUI）

### 画面構成

```
TabView
├── フィード（メイン）
│   ├── ソース種別セグメント: 全て / ニュース / ソーシャル / テック
│   ├── カテゴリ横スクロールフィルタ
│   │   全て / テクノロジー / ビジネス / 開発 / トレンド / ...
│   └── 記事カードリスト
│       ├── サムネイル画像（AsyncImage）+ ソースfavicon
│       ├── タイトル（太字）
│       ├── AI要約（2-3行、処理中は shimmer）
│       ├── ソース名 + ソース種別バッジ + 公開日時
│       └── カテゴリバッジ
│
├── 発見
│   ├── 新しいソース提案カード（承認/拒否）
│   └── Google Newsトレンド記事
│
├── ソース管理
│   ├── ソース種別タブ: ニュース / ソーシャル / テック
│   ├── 登録済みソース一覧（ON/OFF トグル）
│   ├── ソース追加（URL入力）
│   └── ソースごとの記事数・最終更新日
│
└── 設定
    ├── 更新間隔（30分 / 1時間 / 3時間）
    ├── AI処理 ON/OFF
    ├── 発見機能 ON/OFF
    └── データ管理（キャッシュクリア等）
```

### 記事詳細画面

- AI要約をヘッダーに表示
- キーワードバッジ
- 「元記事を読む」→ SFSafariViewController
- 共有ボタン（ShareLink）
- お気に入りボタン

### ViewModel 設計

```swift
@Observable
class FeedViewModel {
    var articles: [Article] = []
    var selectedSourceType: SourceType? = nil  // ニュース / ソーシャル / テック
    var selectedCategory: ContentCategory? = nil
    var isLoading = false
    var error: Error?

    func loadArticles() async { ... }
    func loadMore() async { ... }       // ページネーション
    func refresh() async { ... }        // Pull-to-refresh + RSS再取得
    func filterBySourceType(_ type: SourceType?) { ... }
    func filterByCategory(_ cat: ContentCategory?) { ... }
}

@Observable
class DiscoveryViewModel {
    var suggestions: [DiscoveredDomain] = []  // 提案候補
    var trendingArticles: [Article] = []       // Google News記事

    func checkForNewSources() async { ... }
    func acceptSource(_ domain: DiscoveredDomain) async { ... }
    func rejectSource(_ domain: DiscoveredDomain) { ... }
}

@Observable
class SourcesViewModel {
    var sources: [Source] = []

    func addSource(url: URL) async throws { ... }  // RSS自動検出→追加
    func toggleSource(_ source: Source) { ... }
    func deleteSource(_ source: Source) { ... }
    func checkRemotePresets() async { ... }
}
```

### UI要件

- Pull-to-refresh で最新記事を取得
- 無限スクロール（SwiftData の SectionedFetchResults）
- AsyncImage + キャッシュ
- AI処理中の shimmer アニメーション
- ネットワークエラー時のリトライUI
- ダークモード対応
- Dynamic Type 対応

---

## プロジェクト構成

```
Seekthea/
├── Seekthea.xcodeproj
├── Seekthea/
│   ├── App/
│   │   ├── SeektheaApp.swift
│   │   └── ContentView.swift
│   ├── Models/
│   │   ├── Source.swift
│   │   ├── Article.swift
│   │   └── DiscoveredDomain.swift
│   ├── Services/
│   │   ├── FeedFetcher.swift         // RSS取得
│   │   ├── ContentEnricher.swift     // LPMetadataProviderでOGP補完
│   │   ├── EnrichmentQueue.swift     // 優先度付きエンリッチメントキュー
│   │   ├── AIProcessor.swift         // Apple Intelligence
│   │   ├── RSSDetector.swift         // RSS自動検出
│   │   ├── GoogleNewsDiscovery.swift // ソース発見
│   │   └── RemotePresetService.swift // GitHub Pages
│   ├── ViewModels/
│   │   ├── FeedViewModel.swift
│   │   ├── DiscoveryViewModel.swift
│   │   └── SourcesViewModel.swift
│   ├── Views/
│   │   ├── Feed/
│   │   │   ├── FeedView.swift
│   │   │   ├── ArticleCardView.swift
│   │   │   ├── ArticleDetailView.swift
│   │   │   └── CategoryFilterView.swift
│   │   ├── Discovery/
│   │   │   ├── DiscoveryView.swift
│   │   │   └── SourceSuggestionCard.swift
│   │   ├── Sources/
│   │   │   ├── SourcesListView.swift
│   │   │   └── AddSourceView.swift
│   │   └── Settings/
│   │       └── SettingsView.swift
│   └── Resources/
│       └── preset_sources.json
├── SeektheaShareExtension/
│   └── ShareViewController.swift
└── CLAUDE.md                         // このファイル
```

---

## 開発順序（Claude Codeへの指示）

### Step 1: プロジェクト初期化 + データモデル
- Xcodeプロジェクト作成（SwiftUI, SwiftData）
- Source, Article, DiscoveredDomain モデル定義
- preset_sources.json バンドル

### Step 2: RSS取得の実装
- FeedKit導入（Swift Package Manager）
- FeedFetcher 実装
- プリセットソース1つ（GIGAZINE）でテスト
- フィード一覧画面の仮実装

### Step 3: Content Enrichment
- ContentEnricher 実装（LPMetadataProvider + OGP抽出）
- EnrichmentQueue 実装（優先度制御）
- 記事カードにOGP画像・説明文を反映
- 段階的リッチ化UI（shimmer → 画像フェードイン）

### Step 4: フィードUI完成
- FeedView, ArticleCardView, ArticleDetailView
- カテゴリフィルタ
- Pull-to-refresh, 無限スクロール
- SFSafariViewControllerで元記事表示

### Step 5: Apple Intelligence統合
- Foundation Models framework 導入
- AIProcessor 実装（要約 + カテゴリ分類）
- Guided Generation で構造化出力
- フォールバック処理（AI非対応デバイス）

### Step 6: ソース発見機能
- GoogleNewsDiscovery 実装
- RSSDetector 実装
- DiscoveryView（提案UI）
- 記事内リンク解析（補助）

### Step 7: Share Extension
- App Group 設定
- ShareViewController 実装
- メインアプリとの連携

### Step 8: Remote Preset + 仕上げ
- GitHub Pages リポジトリ作成
- RemotePresetService 実装
- 設定画面
- ダークモード、Dynamic Type、エラー処理

---

## 制約・注意事項

- **マルチプラットフォーム**: iPhone / iPad / Mac 対応。SwiftUIのレイアウトはデバイス幅に応じてアダプティブに。iPadではSplitView、MacではNavigationSplitViewの3カラム構成を検討
- **CloudKit**: Host in CloudKit = ON。`@Attribute(.unique)` は使用不可のため、重複チェックは `articleURL` でコード側で実装。全プロパティにデフォルト値を設定。iCloudアカウント未設定時のフォールバック（ローカルのみ動作）を用意
- **Apple Intelligence**: iPhone 15 Pro以降 + iOS 26+ が必須。非対応デバイスではAI機能を無効化してフォールバック。macOS 26での Foundation Models framework 対応状況も確認すること
- **Foundation Models API**: Guided Generation の実際のAPIシグネチャはiOS 26 SDKで確認すること。上記コードは設計意図を示すもの
- **著作権**: 記事本文は保存しない。RSSのtitle + descriptionのみ保存。アプリ上ではAI要約を表示し、「元記事を読む」で元サイトへ誘導
- **RSS配信元への配慮**: リクエスト間隔を適切に設定（最低30分間隔）。User-Agentを適切に設定
- **Google News RSS**: URLのトピックIDは変更される可能性あり。実装時に最新のURLを確認
- **コスト**: 月額ゼロ（Apple Intelligence = 無料、CloudKit = 無料枠内、GitHub Pages = 無料、RSS = 無料）
- **プライバシー**: データはオンデバイス＋iCloud（Apple管理）のみ。第三者サーバーへのデータ送信なし

---

## Git運用

- コミットメッセージは日本語で書く
- `Co-Authored-By` はコミットに付けない
