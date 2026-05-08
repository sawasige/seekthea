# 改善提案（未着手）

サブエージェントによるコードレビューで挙がった改善項目のうち、**未着手**のもの。
完了済み（Round 1 #1〜#19）は `IMPROVEMENTS_DONE.md` に退避済み。

戦略的な大粒度の新機能・ロードマップは `IMPROVEMENT_PROPOSALS.md` を参照。

---

# Round 2: プラットフォーム別UX & UX専門家レビュー（2026-04-21）

iPhone/iPad/macOS/visionOS の各プラットフォーム専門観点と、UX専門家観点で全体を精査した結果。
それぞれサブエージェントが独立に分析。横断的なテーマも整理。

## 🔴 High Priority

### 20. macOS のキーボードショートカット & メニューバー未実装
- **領域**: macOS / 観点: 使いづらい
- **症状**:
  - File / Edit / View / Window メニューが未定義
  - ⌘R（更新）, ⌘F（検索）, ⌘N（新規）, ⌘W（閉じる）等の標準ショートカットなし
  - macOSアプリとして「未完成」な印象
- **方向性**: `SeektheaApp.swift` に `.commands { ... }` を追加。最低でも更新・検索・お気に入り切替・新ウィンドウを実装
- **関連**: `IMPROVEMENT_PROPOSALS.md` の **K**（キーボードショートカット最小セット、v1.5）と統合検討

### 21. macOS でスワイプ・pull-to-refresh が機能しない
- **領域**: macOS / 観点: 使いづらい
- **症状**:
  - `ScrollViewSwipeHelper` が iOS 専用（`FeedView.swift:699-708`）→ macOS でカテゴリ切替手段がない
  - `.refreshable`（FeedView.swift:761-765）は macOS で無視される
  - macOS ユーザーは更新ボタン以外の操作経路がほぼない
- **方向性**: macOS では Picker/Menu でカテゴリ切替、矢印キーやTrackpadスワイプ認識を追加。pull-to-refreshの代わりに⌘Rショートカット明示

### 22. iPad で NavigationSplitView 未採用
- **領域**: iPad / 観点: 設計
- **症状**:
  - `FeedView.swift:507-690` は NavigationStack のみ
  - regular size class でも記事一覧と詳細を並列表示できない
  - 「iPhone を引き伸ばした見た目」になっている
- **方向性**: regular size class で NavigationSplitView による2-3カラム化（一覧/詳細、必要ならソース一覧も）

### 23. visionOS のホバーエフェクト・タップターゲット未対応
- **領域**: visionOS / 観点: 使いづらい
- **症状**:
  - `.hoverEffect()` `.focused()` 未使用 → 視線フォーカス時の視覚フィードバックなし
  - カテゴリチップ・ボタンのpaddingが iOS基準（`12×6` `8×3`）→ ガイズ+タップの精度的に小さすぎる
  - `SeektheaApp.swift:62` でウィンドウサイズ・スタイル未指定
- **方向性**: `#if os(visionOS)` で hoverEffect追加、タップ領域 44×44pt 以上、`.windowStyle` `.defaultSize` 指定

### 24. ローディングの段階表示がない
- **領域**: UX横断 / 観点: わかりづらい
- **症状**:
  - `FeedView.swift:506-520` でフェッチ中は `ProgressView` のみ
  - 何のフェーズか（取得中/分類中/スコア計算中）がユーザーに見えない
  - 初回起動時の不安感大（特に新規ユーザー）
- **方向性**: `loadingPhase` ステートを追加し、`fetching → classifying → scoring → done` の段階別メッセージ表示。既存の onProgress callback で実現可能

### 25. エラー時のフィードバックが欠落
- **領域**: UX横断 / 観点: わかりづらい
- **症状**:
  - ネットワークエラー、CloudKit同期失敗、AI処理失敗が画面に出ない
  - ユーザーには「なぜ動かないか」が伝わらず、「壊れた」印象に
  - `ContentUnavailableView` は空状態のみ対応
- **方向性**: `error: String?` を `FeedViewModel` に追加し、画面下部にerror banner。`FeedFetcher`/`AIProcessor` から viewModel にエラー通知。再試行ボタンも

## 🟡 Medium Priority

### 26. iPhone 詳細ビューのモード切替ボタンが小さい/届きにくい
- **領域**: iPhone / 観点: 使いづらい
- **症状**: `ArticleDetailView.swift:219-231, 747` の `frame(width: 56, height: 40)` は親指の届く範囲外、Dynamic Type Large で折り返し
- **方向性**: 最小高さ48pt以上、Max機種でも親指で届く位置に再配置
- **関連**: `IMPROVEMENT_PROPOSALS.md` の **I**（モード Picker 化、v1.5）でモード切替の構造を再設計予定

### 27. iPhone でメニュー → 設定への深いナビゲーション
- **領域**: iPhone / 観点: 設計
- **症状**: `FeedView.swift:575-593` の ellipsis メニューから「ソース管理」「発見」「設定」へ。複数ステップで戻りづらい
- **方向性**: 下部タブバーまたは Tab型ナビゲーションを検討。ただしフィード単一画面の設計思想とのトレードオフ

### 28. iPad のソース管理がリスト1列
- **領域**: iPad / 観点: 設計
- **症状**: `SourcesListView.swift:44-95` は List 一辺倒で、iPad 横向きで余白多
- **方向性**: regular size class で 2-3 カラムグリッドに

### 29. iPad でホバー/ポインタ/Drag&Drop 未対応
- **領域**: iPad / 観点: 使いづらい
- **症状**: 外付けキーボード・トラックパッド・マウス利用時に hover効果なし、`.pointerStyle` 未設定、ドラッグ&ドロップなし
- **方向性**: `.hoverEffect()` と `.pointerStyle(.link)` をボタン類に追加。記事のドラッグでソース一覧から記事を移動など

### 30. macOS で Sheet が独立ウィンドウになるべき場面
- **領域**: macOS / 観点: 設計
- **症状**: オンボーディング・ソース追加が sheet で開く（`ContentView.swift:132`, `SourcesListView.swift:100+`）。macOSでは独立ウィンドウが自然
- **方向性**: `openWindow(id:)` 環境変数で別ウィンドウとして開く設計に

### 31. macOS の最小ウィンドウサイズ未指定
- **領域**: macOS / 観点: 使いづらい
- **症状**: `SeektheaApp.swift` の `WindowGroup` にサイズ制約なし。狭く縮めるとレイアウト崩れ
- **方向性**: `.windowResizability(.contentMinSize(width: 800, height: 600))` 等を追加

### 32. visionOS の Ornament 未活用
- **領域**: visionOS / 観点: 設計
- **症状**: `.toolbar` の placement が `.automatic` で背景に埋もれやすい
- **方向性**: `#if os(visionOS)` で `.ornament()` で重要ボタンを浮遊化

### 33. visionOS のアニメーション速すぎ（VR酔い対策不足）
- **領域**: visionOS / 観点: 使いづらい
- **症状**: `FeedView.swift:456, 459`（0.12-0.15秒）等、複数の高速アニメーションが連続発火。visionOSでは0.5-0.8秒推奨
- **方向性**: `#if os(visionOS)` でアニメーション duration を緩める

### 34. スコアシステムの説明責任なし
- **領域**: UX横断 / 観点: わかりづらい
- **症状**: `ArticleCardView.swift:58-62` で `%` スコアを表示するが、何の数値・どう計算されているかが伝わらない
- **方向性**: スコア横に `?` アイコン → tap/hover で tooltip。`ScoreBreakdownView` への動線を明示
- **関連**: `IMPROVEMENT_PROPOSALS.md` の **D**（学習結果の可視化、v1.4〜v1.5）と統合検討

### 35. Discovery の「提案理由」表示なし
- **領域**: UX横断 / 観点: 使いづらい
- **症状**: `DiscoveryView.swift` の各行に「言及元」「言及数」「カテゴリ傾向」等の根拠表示なし。Google News自動発見という強みが埋もれている
- **方向性**: 各行に言及元ファビコン3-5個、言及回数バッジ、カテゴリタグを追加

### 36. カテゴリフィルタの現在地が不明
- **領域**: UX横断 / 観点: わかりづらい
- **症状**: 横スクロールカテゴリ切替で、全体何個・今どこにいるかが分からない
- **方向性**: `3/14` のドットindicator か、Picker で全カテゴリ俯瞰可能に

### 37. 既読UIを `.secondary` に統一
- **領域**: UX横断 / 観点: 使いづらい
- **症状**: 現状 `opacity 0.6` + 既読バッジ。複数エージェントから「opacity だけだと『価値ない』に見える」「`foregroundStyle(.secondary)` が優雅」との指摘
- **方向性**: opacity → secondary、または既読タブ分離。#16の延長戦

### 38. オンボーディング完了後の待機感
- **領域**: UX横断 / 観点: わかりづらい
- **症状**: `OnboardingView.swift:89-98` で `addCategories` 後 `fetchAll` を await するが、`OnboardingDoneView` には進捗表示なし
- **方向性**: DoneView に `loading state` を表示。「記事を準備中...」+ ProgressView

## 🟢 Low Priority

### 39. iPhone の Submit Label / onSubmit 未設定
- `AddSourceView.swift:29-30` のテキスト入力で Return キー後の自動確定がない
- `.submitLabel(.done)` と `onSubmit` modifier を追加

### 40. macOS の SourcesListView frame が 700px 制限
- `SourcesListView.swift:91-92` が macOS でも幅制限。広いウィンドウで活かせない
- `#if os(macOS)` で制限解除、iPad は 700 のまま

### 41. visionOS で Material 使い分けが画一的
- カード `.regularMaterial` 一律。visionOSでは `.thickMaterial` で奥行き、`.ultraThinMaterial` で軽い階層化が望ましい
- 階層に応じて使い分け

### 42. AI失敗時の状態が不明確
- 「分類できませんでした」表示と再試行ボタンがない
- 失敗理由（非対応デバイスなど）も hint で説明
- **状態確認要**: PR #142（分類エラー区別、2026-05-04）で部分対応済みかも。要再確認

### 43. 「お気に入り」と「閲覧履歴」モードのセマンティクス曖昧
- `isFavorite` と `isRead` の逆順という異なる軸を並列表示
- 「保存済み」に名称統一、または4モード目に「アーカイブ」追加

### 44. Live Activities / Widget 未対応
- iOSホーム画面ウィジェット、ロック画面ウィジェットなし
- 「ロック画面に最新トレンド1件」程度なら低コストで習慣化に効く
- **関連**: `IMPROVEMENT_PROPOSALS.md` の **C**（ウィジェット）は単独不採用、F（ダイジェスト通知）とセット採用時に再評価

### 45. 多言語対応なし
- 日本語のみ、英語・他言語ローカライズなし
- App Store グローバル展開時の障壁

---

## Round 2 まとめ

### 横断テーマ
1. **iOS-firstバイアス**: `#if os(macOS)` 分岐は「iOS機能を無効化」目的が多く、各プラットフォーム最適化の代替実装が不足
2. **フィードバック欠落**: ローディング/エラー/スコア/AI失敗、いずれもユーザーに何が起きているか伝わらない
3. **既読UIの再検討**: opacity 0.6 + バッジ構造を再評価する声が複数エージェントから
4. **習慣化の仕掛け不足**: ウィジェット未実装が継続利用の最大の弱点

### 着手順の推奨（コスパ順）

**短期（1-2週）**:
1. **#24 ローディング段階表示** — 既存onProgressに乗せるだけ、UX効果大
2. **#25 エラーバナー統合** — viewModelに1プロパティ追加、画面に1Banner
3. **#37 既読UI改善** — opacity → secondary の単純変更

**中期（1-2ヶ月）**:
4. **#22 NavigationSplitView (iPad)** — iPad 体験の根本改善
5. **#20 macOS keyboard/menu** — macOS が「アプリらしく」なる（PROPOSALS K と統合）
6. **#23 visionOS hover/タップ拡大** — visionOS が「拡大版iPad」を脱する
7. **#44 Widget実装** — 習慣化に直結（PROPOSALS C と統合）

**長期（中期完了後）**:
8. **#35 Discovery提案理由** — 強みの可視化
9. **#21 macOS スワイプ代替** — 細部の磨き
10. **#34 スコア説明** — 信頼性向上（PROPOSALS D と統合）

---

## メモ

- 本ファイルは2026-04-21時点のレビュー結果（Round 2）を残したもの
- Round 1（#1〜#19）は完了済みで `IMPROVEMENTS_DONE.md` に退避（2026-05-08）
- 各項目は仕様変更を伴うものもあるため、着手前に方向性を再確認推奨
- `IMPROVEMENT_PROPOSALS.md`（戦略的な大粒度新機能のロードマップ）と相互参照しながら優先順位を判断
