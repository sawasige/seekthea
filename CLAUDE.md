# Seekthea — パーソナルトレンドアグリゲーター

## プロジェクト概要

ニュースサイト・ソーシャルメディア・テックコミュニティからRSSでトレンドを収集し、Apple Intelligenceでオンデバイス要約・カテゴリ分類を行うマルチプラットフォームアプリ。Google News RSSをソース発見エンジンとして活用し、新しいソースを自動的に提案する。

> **名前の由来**: Seek（探し求める）+ Thea（θέα: ギリシャ神話の視覚の女神 / ギリシャ語で「眺め・視界」）。ウェブ全体のトレンドを見通して、探し出すアプリ。

## 技術スタック

| レイヤー | 技術 | 備考 |
|----------|------|------|
| RSS取得・パース | FeedKit | Swift製、RSS/Atom/JSON Feed対応 |
| コンテンツ補完 | OGP抽出 | 記事URLからog:description/og:imageを取得 |
| AI要約・分類 | Foundation Models framework | iOS 26+、オンデバイス、無料 |
| DB＆同期 | SwiftData + CloudKit | Host in CloudKit = ON |
| UI | SwiftUI | マルチプラットフォーム対応 |
| CI/CD | Xcode Cloud | ビルド・TestFlight配信 |
| メタデータ管理 | fastlane | App Store Connectへのアップロード |
| ランディングページ | GitHub Pages | docs/ ディレクトリから自動デプロイ |

## 動作要件

- **対応プラットフォーム**: iPhone / iPad / Mac / Apple Vision Pro
- iOS 26+ / iPadOS 26+ / macOS 26+ / visionOS 26+
- AI要約にはApple Intelligence対応デバイス（iPhone 15 Pro以降）が必要
- AI非対応デバイスでは要約・分類なしのフォールバック動作
- iCloudアカウント（CloudKit同期に必要）

## データモデル

### Source
- `id`, `name`, `feedURL`, `siteURL`, `category`, `isActive`, `isPreset`, `addedAt`, `lastFetchedAt`, `articleCount`, `ogImageURL`
- `category` でプリセットカテゴリ（ニュース/テクノロジー/開発等）を管理
- ※ `SourceType` enum は廃止済み。カテゴリベースに移行

### Article
- `id`, `title`, `articleURL`, `leadText`, `imageURL`, `publishedAt`, `fetchedAt`
- OGP: `ogDescription`, `ogImageURL`, `siteFaviconData`, `isEnriched`
- AI: `summary`, `aiCategory`（カンマ区切り複数カテゴリ）, `keywordsRaw`, `keywordsEnRaw`, `isAIProcessed`
- パーソナライズ: `relevanceScore`
- ソース追跡: `sourceFeedURL`, `sourceName`
- ユーザー操作: `isRead`, `isFavorite`

### UserCategory
- ユーザー編集可能なカテゴリリスト（SwiftData、CloudKit同期対応）
- デフォルト: 政治, 経済, 社会, 国際, テクノロジー, 科学, スポーツ, エンタメ, ライフ, 開発

### UserInterest
- ユーザーが設定する興味トピック（パーソナライズ用）

### DiscoveredDomain
- Google Newsから自動発見されたドメインの記録

## プリセットカテゴリ（14カテゴリ）

ニュース, テクノロジー, 開発, ビジネス, エンタメ, アニメ・漫画, ゲーム, サイエンス, スポーツ, クルマ・バイク, 話題, コラム, ライフスタイル, 掲示板まとめ

## 画面構成

```
フィード（全画面）
├── モード切替: おすすめ / 新着 / お気に入り / 閲覧履歴
├── カテゴリ横スクロールフィルタ（横スワイプ切替）
└── 記事カードリスト（通常/コンパクト切替）
    └── 記事詳細（UIPageViewControllerでスワイプページング）
        └── リーダー / AI要約(WebView) / Web の3モード

設定
├── ソース管理（登録済み/追加の2タブ、DisclosureGroupで折りたたみ）
├── ソース発見
├── カテゴリ管理
├── 興味トピック
├── 更新間隔 / AI処理 / 発見機能
├── データ管理（記事削除・全初期化）
└── 情報（バージョン・ライセンス・利用規約・プライバシーポリシー・サポート）

オンボーディング（初回のみ）
├── ウェルカム
├── カテゴリピッカー（popularソース選択）
└── 完了
```

## プロジェクト構成

```
Seekthea/
├── Seekthea.xcodeproj
├── Seekthea/
│   ├── SeektheaApp.swift
│   ├── ContentView.swift
│   ├── Info.plist
│   ├── Models/
│   │   ├── Source.swift
│   │   ├── Article.swift
│   │   ├── DiscoveredDomain.swift
│   │   ├── UserCategory.swift
│   │   ├── UserInterest.swift
│   │   ├── CategoryIcon.swift
│   │   └── PresetLoader.swift
│   ├── Services/
│   │   ├── FeedFetcher.swift
│   │   ├── AIProcessor.swift
│   │   ├── InterestEngine.swift
│   │   ├── RSSDetector.swift
│   │   ├── ReadabilityExtractor.swift
│   │   ├── GoogleNewsDiscovery.swift
│   │   └── AppGroupConstants.swift
│   ├── ViewModels/
│   │   ├── FeedViewModel.swift
│   │   ├── DiscoveryViewModel.swift
│   │   └── SourcesViewModel.swift
│   ├── Views/
│   │   ├── Feed/
│   │   │   ├── FeedView.swift
│   │   │   ├── ArticleCardView.swift
│   │   │   ├── CompactArticleCardView.swift
│   │   │   ├── ArticleDetailView.swift
│   │   │   └── CategoryFilterView.swift
│   │   ├── Sources/
│   │   │   ├── SourcesListView.swift
│   │   │   ├── SourcePreviewView.swift
│   │   │   ├── SourceThumbnailView.swift
│   │   │   └── AddSourceView.swift
│   │   ├── Settings/
│   │   │   ├── SettingsView.swift
│   │   │   ├── CategorySettingsView.swift
│   │   │   ├── InterestSettingsView.swift
│   │   │   └── LicensesView.swift
│   │   ├── Onboarding/
│   │   │   ├── OnboardingView.swift
│   │   │   ├── OnboardingWelcomeView.swift
│   │   │   ├── OnboardingCategoryPickerView.swift
│   │   │   └── OnboardingDoneView.swift
│   │   └── Discovery/
│   │       └── DiscoveryView.swift
│   ├── Resources/
│   │   ├── preset_sources.json
│   │   └── licenses.json
│   ├── Assets.xcassets/
│   └── ci_scripts/
│       └── ci_post_clone.sh          // Xcode Cloud用ビルド番号自動設定
├── docs/                              // GitHub Pages（ランディングページ等）
│   ├── index.html
│   ├── privacy.html
│   ├── terms.html
│   ├── support.html
│   └── assets/
├── fastlane/                          // App Storeメタデータ管理
│   ├── Fastfile
│   ├── Appfile
│   ├── metadata/
│   ├── screenshots/                   // iOS (iPhone + iPad)
│   ├── screenshots-mac/
│   └── screenshots-visionos/
├── .github/workflows/
│   └── pages.yml                      // docs/ 変更時にGitHub Pagesデプロイ
├── CLAUDE.md
└── README.md
```

## CloudKit同期の対象

| 同期する | 同期しない |
|----------|------------|
| お気に入り（isFavorite） | RSSフィードのキャッシュデータ |
| 既読状態（isRead） | AI処理のキュー状態 |
| ソース設定（追加/削除/ON/OFF） | — |
| AI要約結果 | — |
| 発見ドメインの拒否リスト | — |
| ユーザーカテゴリ | — |
| ユーザー興味トピック | — |

## 制約・注意事項

- **CloudKit**: `@Attribute(.unique)` は使用不可。重複チェックはコード側で実装。全プロパティにデフォルト値を設定
- **Apple Intelligence**: AI非対応デバイスではAI機能を無効化してフォールバック
- **著作権**: 記事本文は保存しない。RSSのtitle + descriptionのみ保存。「元記事を読む」で元サイトへ誘導
- **RSS配信元への配慮**: リクエスト間隔を適切に設定（最低30分間隔）
- **プライバシー**: データはオンデバイス＋iCloud（Apple管理）のみ。第三者サーバーへのデータ送信なし

## 将来の改善案

### ソース発見
- **プリセットの拡充**: ニュースに限定せず、ゲームメーカー、音楽、映画、テックブログ、個人ブログなどジャンルを問わず面白いRSSを充実させる。カテゴリも細分化する
- **記事内リンクからのソース発見**: 登録済みソースの記事本文に含まれるリンクを辿って新しいRSSソースを発見する。課題: サイドバー/フッターのノイズ除去、本文抽出にWebViewが必要
- **Google News以外のトレンドソース**: はてなブックマークなど他のトレンドソースからもドメインを発見する

### フィード体験
- **特定ソースだけのフィード表示**: カテゴリフィルタだけでなく、特定のソースで絞り込んで記事を読めるようにする
- **記事の重複検出**: 同じニュースを複数ソースから取得した場合にまとめる
- **既読記事の自動アーカイブ**: 古い記事を自動的に非表示にする
- **オフライン対応**: 記事本文のキャッシュ

### AI機能
- **トピックごとの自動まとめ**: 同じテーマの複数記事を1つの要約にまとめる
- **興味スコアのフィードバック**: 「これは興味ない」のワンタップで学習精度を上げる

### マルチプラットフォーム
- **ウィジェット対応**: ホーム画面にトレンド表示
- **Apple Watch対応**: 要約だけ読める

### ソーシャル
- **ソースリストの共有**: 自分のプリセットを友人にシェア
- **おすすめソースのコミュニティ**: ユーザー同士でソースを推薦

## Git運用

- コミットメッセージは日本語で書く
- `Co-Authored-By` はコミットに付けない
- mainに直接プッシュしない。ブランチを切ってPRを作成する
