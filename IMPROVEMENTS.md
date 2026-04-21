# 改善提案

4つのサブエージェント（Feed/Sources/AI/Lifecycle）でコードレビューした結果をまとめたもの。優先度順、発見領域・観点・推奨アクション付き。

---

## 🔴 High Priority

### 1. AI処理の再生成・修正フロー
- **領域**: AI / 観点: 仕様矛盾 + 足りない機能
- **症状**: 分類失敗時にソースカテゴリへ暗黙代入、ユーザー通知なし。一度失敗したら救済手段なし。誤分類のフィードバックループも存在しない。
- **方向性**:
  - 記事詳細に「AI要約を再生成」「カテゴリを修正」アクションを追加
  - 分類失敗を明示するUI（ラベル「未分類」など）
  - 修正アクションは `learnFromHistory` と連動して学習に反映
- **対応**: ✅ Phase A 完了（PR #41, 2026-04-20）
  - AI分類失敗時のソースカテゴリへのフォールバックを廃止、`aiCategory = ""`でマーク
  - カードに「未分類」ラベルを表示
  - 記事詳細toolbar「...」メニューに「AI処理を再実行」追加（要約・分類両方）
  - **残タスク（Phase B）**: カテゴリ修正UI + 学習連動

### 2. おすすめソートの安定性向上
- **領域**: Feed / 観点: 仕様矛盾
- **症状**: バックグラウンドで分類完了 → `updateRelevanceScores()` → 表示順が変動。既読セッション保護はあるがスコア更新には未対応。
- **方向性**:
  - スコア再計算もセッション中はスナップショット適用
  - 明示的refresh時のみ再ソート
  - もしくは: スコア更新を反映するタイミングを集約（今は分類1件ごとに走る）
- **対応**: ✅ 完了（PR #42, 2026-04-20）
  - `lockedSortKeys: [UUID: Double]`を追加し、表示時にスコアをlazy capture
  - フォアグラウンド継続中はロックされたスコアでソート → 順序完全固定
  - **再ランキングのトリガー**:
    - バックグラウンド復帰時（`wasBackgrounded`フラグでscenePhase遷移を追跡）
    - Pull-to-refresh
    - macOS更新ボタン
  - 上記タイミングで`lockedSortKeys`と`sessionReadIDs`を同時クリア → 既読も下に移動
  - **設計判断**: 「セッション中は完全に位置固定、新セッションで再ランク」をユーザー操作不要で実現。スコア更新の即時反映 vs 並びの安定性のトレードオフは「アプリ閉じて開き直す」という自然な区切りで解消。

### 3. ソース管理の非対称性解消
- **領域**: Sources / 観点: 仕様矛盾 + 使いづらい
- **症状**:
  - プリセット削除に確認ダイアログなし（手動追加にはあり）
  - SourcePreviewViewからプリセット削除不可（手動追加は可）
  - 手動追加エラー時に画面が閉じず復帰経路不明
- **方向性**:
  - プリセット削除にも確認ダイアログ追加
  - SourcePreviewViewにプリセット削除アクション追加
  - AddSourceViewのエラー後フローを整理
- **対応**: ✅ 完了（PR #43, 2026-04-20）
  - **#1**: 確認ダイアログは付けず、追加/削除でハプティックを使い分け
    - 追加: `UISelectionFeedbackGenerator().selectionChanged()`（軽いtick）
    - 削除: `UIImpactFeedbackGenerator(style: .medium)`（重め）
    - トーストはうざいので不採用
  - **#2**: SourcePreviewViewの登録済みプリセットに「削除」ボタン追加（同じハプティック適用）
    - 副バグ修正: プレビューで追加/削除した時に一覧のマークが更新されない問題
      - SourcesListViewに`onChange(of: sources.count)`を追加してviewModelキャッシュを再構築
      - `SourcesViewModel.refreshRegisteredURLs`を内部privateからpublicに変更
  - **#3-A**: AddSourceViewでURL編集時に`addingError`を自動クリア、URL形式バリデーション追加（http/https + host必須）
  - **#3-B**: エラー文言を「RSSフィードが見つかりませんでした。サイトのトップページのURLを試すか、RSSのURLを直接入力してください。」に詳細化

### 4. 「すべて初期化」の取りこぼし修正
- **領域**: Lifecycle / 観点: 仕様矛盾
- **症状**:
  - DiscoveredDomain等の削除取りこぼし可能性
  - AppStorageキー削除が手動リスト、新規キー追加時に漏れやすい
  - ReaderCache等の新キャッシュも考慮されていない
- **方向性**:
  - 削除対象を一箇所に集約（例: `ResettableStorage`プロトコル）
  - 全SwiftData modelの削除を網羅
  - ReaderCacheなど追加キャッシュもクリア
- **対応**: ✅ 完了（PR #44, 2026-04-20）
  - `ReaderCache.clear()`メソッドを追加し、resetAllDataで呼び出し
  - 手動の@AppStorageキー一覧（5件）を撤廃 → `UserDefaults.standard.removePersistentDomain(forName: bundleID)` でアプリ全体を一括削除
  - 将来`@AppStorage`キーが追加されても自動的にカバーされる
  - SwiftData model削除は既に5モデル全てカバー済みだったので変更なし
  - `PendingSourcesStore.clear()`はApp Group用なので別途呼び出し継続

### 5. CloudKit同期透明性
- **領域**: Lifecycle / 観点: わかりづらい
- **症状**: 同期失敗を黙ってローカルモードに切替。重複削除も裏で走る。ユーザーは何が起きているか不明。
- **方向性**:
  - 同期状態（CloudKit接続中/失敗/ローカルのみ）を設定画面に表示
  - エラー時は1度だけバナーで通知
  - 重複削除はログ・統計を残す
- **対応**: ✅ Phase A 完了（PR #45, 2026-04-20）
  - `CloudSyncStatus`シングルトン追加（@Observable @MainActor）
  - ModelContainer初期化結果 + `CKContainer.default().accountStatus()` の組み合わせで判断
  - 状態enum: `.available` / `.noAccount` / `.restricted` / `.temporarilyUnavailable` / `.couldNotDetermine` / `.localOnly` / `.unknown`
  - 各状態にlabel + descriptionを定義し、SettingsView「同期」セクションに表示
  - SeektheaApp起動時 + scenePhase active復帰時に`CloudSyncStatus.shared.refresh()`を呼ぶ
  - **残タスク**: エラーバナー / 重複削除の可視化（Phase B、必要なら後で）

---

## 🟡 Medium Priority

### 6. 興味トピックの英訳問題
- **領域**: AI / 観点: 仕様矛盾
- **症状**: ユーザーが日本語トピック追加時、`topicEn = topic`で日本語のまま保存 → embedding機能せず
- **方向性**: 追加時に簡易翻訳API or 手動英訳入力欄
- **対応**: ✅ 完了（PR #46, 2026-04-20）
  - `AIProcessor.translateToEnglish(_:)` を追加（FoundationModelsで日→英変換）
  - 追加時に非ASCIIトピックならバックグラウンドで翻訳実行、topicEnを更新
  - 翻訳中はトピック行にProgressView、失敗時は「英訳が取得できなかったため、セマンティック類似のスコアは効きません」の警告を表示
  - **注**: `topic`(日本語)は引き続き`computeKeywordScore`で文字列マッチに使われるため、翻訳失敗してもキーワードスコアは効く（セマンティックスコアだけ無効化）
  - **注**: Apple Intelligenceのセーフティガードレールで一部の単語が翻訳不可。失敗時は警告UIで通知

### 7-A. スコア表示の整合性とアクセス性
- **領域**: AI / 観点: 仕様矛盾 + 使いづらい
- **症状**:
  - カードでスコア非表示（< 0.1）の記事を開くと内訳画面で50%+のスコアが見える
  - 原因: 表示回数ペナルティで保存値は低いが、既読化後の試算では高くなる
  - スコア内訳を見るために記事を開く必要がある
- **対応**: ✅ 完了（PR #48, 2026-04-20）
  - **記事を開いたら自動再スコア**: ArticleDetailView.onAppearでisRead=true後にInterestEngine.rescore(article:)を呼ぶ。既読化でペナルティ解除されたスコアが保存される
  - **カードの%閾値撤廃**: `> 0.1` → `> 0`に変更、`max(1, round)`で最低1%表示。未計算（0）のみ非表示
  - **カード長押しメニューに「スコアの内訳」追加**: 開かずに内訳を確認できる。FeedViewのcontextMenuに項目追加

### 7. スコア根拠の説明
- **領域**: AI / 観点: 足りない機能
- **症状**: なぜこの記事が上位かが不明、`relevanceScore`の数値も非表示（モード次第）
- **方向性**: 記事詳細にスコア内訳を表示（キーワード一致, カテゴリスコア, 履歴類似度）
- **対応**: ✅ 完了（PR #47, 2026-04-20）
  - `InterestEngine.explainScore(for:)` を追加し、`ScoreBreakdown` 構造体で内訳を返す
  - 記事詳細「...」メニューに「スコアの内訳」追加、シートで表示
  - 表示内容: 合計スコア / 各要素のマッチ詳細・重み・類似度・寄与 / 補正（新着ボーナス・表示回数ペナルティ）
  - 計算過程を「マッチ → 合計 → 正規化 → 重み」の4ステップで可視化
  - **設計変更**:
    - **categoryScore廃止**: AI分類の信頼性が低く、ユーザー手動修正のモチベーションも乏しいため。重みを keyword 30%/semantic 40%/category 30% → keyword 40%/semantic 60% に再配分
    - **セマンティック類似の重複排除**: 「同じ記事キーワードが複数の興味と類似」して同一単語が複数回加算される問題を、各記事キーワードに対して最も近い興味1つだけ採用するアルゴリズムに変更
    - **マッチ行の透明化**: タイトル一致(×3)/キーワード一致(×2) の区別、重み・類似度・寄与を明示
    - **保存値との差を注釈**: フィードに表示されているスコア（前回更新時の保存値）と内訳画面の試算（現在のデータ）が異なる旨を明記

### 8. Weight=0の興味トピック設定
- **領域**: AI / 観点: 仕様矛盾
- **症状**: コメントに「0=無関心」とあるがUIではSlider 0.1-2.0で0設定不可
- **方向性**: Sliderの下限0を許容、または「無関心」専用トグル追加
- **対応**: ✅ 完了（PR #49, 2026-04-20）
  - 「無関心」概念を実装するメリットが薄いため、コメントの修正だけで対応
  - `UserInterest.weight`コメントを「スコアの倍率。デフォルト1.0、Slider範囲は0.1〜2.0」に更新
  - 「無関心」が必要になった場合は別タスクで負ウェイトサポートまたは別UIで「ブロックリスト」を設計予定（現スコア式は負入力で破綻するため要refactor）

### 9. カテゴリチップのトグル挙動
- **領域**: Feed / 観点: わかりづらい
- **症状**: 通常チップは再タップで解除、「全て」チップは別動作。違いが視覚的に伝わらない。
- **方向性**: 「全て」を選択中は他チップを非選択UIにする、もしくは挙動統一
- **対応**: ❌ WontFix（2026-04-20）
  - 現状の挙動: 「全て」=クリア / カテゴリチップ=トグル（再タップで解除）
  - C案（カテゴリチップは選択のみで解除は「全て」）を試したが、隠れUIとして残す判断
  - 利用者が困るレベルではない、知ってれば便利な機能として現状維持

### 10. リーダー抽出失敗時のリトライ
- **領域**: Feed / 観点: 使いづらい
- **症状**: 同条件で再実行するため成功率変わらず「何度やっても同じ」
- **方向性**: リトライ時にUserAgent変更、タイムアウト延長など条件変更
- **対応**: ✅ 完了（PR #51, 2026-04-20）
  - 実態としてリトライは（ネットワークやJSキャッシュで）効くケースが多いため、UA変更等の複雑化は不要と判断
  - 課題は「リトライボタンが見つからない」点だったため、失敗通知バナー内に「再読み込み」「×」ボタンを埋め込み
  - toolbarからリトライアイコンを撤去（ツールバー窮屈化対応も兼ねる）
  - auto-dismiss（3秒で消える）を廃止、ユーザーが ×タップ or 再読み込み成功するまで通知を残す

### 11. スキップしたソースの即時復元
- **領域**: Sources / 観点: 使いづらい
- **症状**: 復元は設定画面奥、誤スキップの即時undoなし
- **方向性**: スキップ直後に下部スナックバー「取り消す」、もしくは発見画面に「スキップ済み」セクション
- **対応**: ✅ 完了（PR #52, 2026-04-20）
  - 発見画面のリスト下部に「スキップ済み (N)」折りたたみセクションを追加（デフォルト閉じ）
  - 各行にサムネイル・フィード名・ドメイン・「復元」ボタン
  - ヘッダータップで展開/収納、復元で`isRejected=false`に戻して通常セクションに復帰
  - スナックバー案より常時可視で、後日の復元にも対応

### 12. AI要約進捗の状態同期 + 要約のキャッシュ化
- **領域**: Feed / 観点: 使いづらい + 設計一貫性
- **症状**:
  - 記事詳細離脱中も処理は続くが、戻ってきても進捗が見えない
  - 同じ記事を再オープンすると `analyze()` が重複実行される
  - 別記事を10件開いたら処理が並列爆発する
  - AI要約だけ永続化されており、リーダー本文（メモリキャッシュのみ）と設計が不整合。要約は他用途で使われていない（display only）
- **方向性**: グローバルな処理状態をDiscoveryManager同様に共有
- **対応**: ✅ 完了（PR #53, 2026-04-20）
  - **AI要約をキャッシュ化**: `Article.summary` と `isAIProcessed` を削除し、新設 `AISummaryCache` (`@Observable @MainActor`) のメモリ管理に。リーダー本文と設計を統一
  - **AIProgressTracker** を `Set<UUID>` から `[UUID: Task<Void, Never>]` に変更し、別記事Task開始時に既存タスクを自動キャンセル（最新優先）
  - **AIProcessor.analyze** が `Task.isCancelled` チェックを行い、キャンセル時はキャッシュ書き込みをスキップ
  - **AISummaryView** が `AISummaryCache` を直接観察 → 再表示時にも進捗・結果が復元
  - **SettingsView.resetAllData** で `AISummaryCache.shared.clear()` を呼ぶ
  - **トレードオフ**: アプリ再起動・別端末で要約は再生成されるが、要約は display 用途なので影響軽微
- **対応**: ✅ 完了（PR #53, 2026-04-20）
  - `AIProgressTracker`シングルトン追加（@Observable @MainActor、`Set<UUID>`で処理中記事ID管理）
  - ArticleDetailViewのローカル`isAIProcessing` @Stateを撤廃
  - AISummaryViewが直接Trackerを観察 → 再表示時にも進捗が復元される
  - loadContent / reprocessAI でmarkStarted/markFinished、重複ガードもTracker参照に
  - **副次効果**: 同じ記事を処理中に再度開いても`analyze()`が二重実行されない

### 13. 学習重みの単位統一
- **領域**: AI / 観点: わかりづらい
- **症状**: ユーザー入力（Slider 0.1-2.0）と学習結果（normalized 0-1）で単位が異なる、比較不能
- **方向性**: 表示単位を統一、もしくは並列表示時に正規化変換
- **対応**: ✅ 完了（PR #54, 2026-04-20）
  - **計算の統一**: `InterestEngine` で明示的興味に掛けていた `× 2` を削除。Slider の値は既に強弱を調整できるため二重の優位付けは不要と判断
  - **表示の統一**: 明示的興味と学習重みを両方 `×N.NN` の倍率表記に統一。「%」が何に対する%か曖昧だった問題も同時に解消
  - **副次的影響**: 明示的興味の相対的な影響力が約半分に下がる（Slider 1.0 が学習 max の 2倍から 1.0倍に）。スコア全体も若干下がる
  - **未解決の関連課題**: スコア全体が常時10%前後で低いという指摘が残る（正規化式 `x/(x+2)` が厳しすぎる可能性）

### 14. 記事クリーンアップの実行保証 + ステータス表示統一
- **領域**: Lifecycle / 観点: わかりづらい + 設計
- **症状**:
  - 24時間throttleのせいで長時間フォアグラウンド利用中にクリーンアップが走らない
  - `ArticleCleanupService`独自の`statusMessage`がfetchAll実行中の`feedStatus`と理論上重なって、直列処理なのに複数ステータスが並ぶ設計不整合
- **方向性**: 説明文を実態に合わせる、もしくはBGAppRefreshTaskで保証
- **対応**: ✅ 完了（PR #55 + #56, 2026-04-20）
  - **実行保証 (PR #55)**:
    - `runIfDue` と `lastRunAt` UserDefaults を廃止、`run` に一本化、throttleなし
    - `FeedFetcher.fetchAll` 末尾で毎回 `await cleanup.run` を呼ぶ
    - `SeektheaApp` のscenePhase activeでも直接runを呼ぶ
  - **ステータス表示統一 (PR #56)**:
    - `ArticleCleanupService.statusMessage` (@Observable) を廃止、`onProgress` コールバック方式に変更
    - `FeedFetcher.fetchAll` が自分の `onProgress` をそのままcleanupに流す → refresh時は同じ status channel で表示一本化
    - 直列フロー: 「取得中... → 削除中... → スコア計算中...」と順番に切り替わる（stackしない）
    - 並列（discovery等）: 別source維持で引き続きstack表示
    - `FeedView`のoverlayから`cleanupStatus`行を撤去

### 15. オンボーディング再発火リスク
- **領域**: Lifecycle / 観点: 使いづらい
- **症状**: CloudKit同期遅延で`sources.isEmpty`が誤検知され、機種変・再インストール時にオンボーディングが誤表示される
- **検討経緯**:
  - 当初案「`@AppStorage`完了フラグ」は、新端末ではフラグもクリーンなため本命シナリオ（機種変）で効果なし
  - CloudKitの同期タイミング自体は制御不能、raceは inherent
  - `@Query`でオンボーディング表示中もsourcesを観察できることに着目
- **対応**: ✅ 完了（PR #58, 2026-04-20）
  - `OnboardingView`に`@Query private var sources: [Source]`を追加、`onChange`でsync到着を検知
  - **welcome画面**: sources非空になったら無言で自動dismiss（ユーザーがまだ何も選んでいない）
  - **categoryPicker画面**: アラートモーダル表示で強制判断（「既存の設定を使う」/「選択を続ける」）
    - 当初overlayバナー案 → レイアウト崩れ + 気づかず選択を続けてしまうリスクで却下
    - アラートで割り込み、ユーザーの時間とデータを守る
  - **done画面**: 既にaddPopularSources完了後なので何もしない
  - `addPopularSources`は`existingURLs`でdedup済のため、「選択を続ける」を選んでもデータ破損なし

---

## 🟢 Low Priority

### 16. 既読インジケーターの二重表現
- **症状**: カードで不透明度0.6 + 右上に`checkmark.circle.fill`（アクセントカラー）。二重表現かつチェックマークのアクセントカラーが「選択/お気に入り」の意味と混同されやすい
- **検討経緯**:
  - opacityのみではユーザーに分かりづらかったため、過去にバッジを追加した経緯あり。バッジ自体は残したい
  - SFシンボルで「既読」を完璧に表すものは存在しない（checkmark=完了、eye=見た、envelope.open=メール慣習等、どれも厳密には異なる）
  - 未読ドット反転（メール型）はニュースの「未読がデフォルト」文脈に合わない
- **対応**: ✅ 完了（PR #59, 2026-04-20）
  - アイコン→**テキストバッジ「既読」**に変更。意味論の曖昧さを排除
  - 色はセカンダリ、背景は`.ultraThinMaterial`のCapsuleで控えめに
  - opacity 0.6は併存させることで、一覧での視認性とバッジの明示性を両立
  - `ArticleCardView`と`CompactArticleCardView`の両方に反映（サイズはfont/paddingで調整）

### 17. 印象カウントのリセット手段なし
- **症状**: 未読でも何度も表示で減点される記事が永続的に下がる。加えて「何度も表示」のカウントが過剰（毎起動・毎スクロールで +1）で、ベーススコアが低い時に影響が急激に効く
- **検討経緯**:
  - 当初案「印象リセットボタン」は、ユーザーに内部用語（impressionCount）への理解を要求してしまい意味不明
  - 自動減衰は「見たけど選ばなかった」事実を時間で覆す根拠が弱い
  - 「視界に入った」を「選ばなかった」と解釈するには精度不足、ただしスクロール検知・per-card offset追跡は過剰な複雑性
- **対応**: ✅ 完了（PR #60, 2026-04-20）
  - **セッション重複排除**: `sessionImpressed: Set<UUID>` で1セッションにつき最大1カウント。毎起動・毎スクロールでの累積を防ぐ
  - **初回2回免除 + 上限8カウント**: `InterestEngine.impressionPenalty(count:)` に統一
    - count 0〜2 → ×1.00（免除）
    - count 3 → ×0.87（初期減衰を緩和）
    - count 10+ → ×0.45（下げ止まり、永遠問題を解決）
  - 3箇所（scoreArticles / rescore / breakdown）のインライン式を1つの static helper に集約
  - **リセットUIは作らない**: ユーザーに内部概念を露出させないため

### 18. カテゴリの複数タグ非対応
- **状態確認時の発見**: `Article.aiCategory`は既にカンマ区切り対応、`categories`計算プロパティで配列展開、表示・フィルタも `categories.contains` で複数前提に書かれていた。穴は**InterestEngineのスコアリング学習部分のみ**で、raw `aiCategory`を直接1キーとして扱っていた
- **設計意図**: AIの精度が低いため意図的に1カテゴリに絞っているが、精度向上時に複数返せるよう周辺は複数前提を維持したい
- **対応**: ✅ 完了（PR #62, 2026-04-21）
  - `InterestEngine.learnFromHistory`の2箇所を `if let cat = article.aiCategory` から `for cat in article.categories` に変更
  - 現在AIが単一を返している間も動作（`categories` は1要素配列）
  - 将来AIが複数を返したら、そのまま全カテゴリが学習対象になる
  - AI側（`AIProcessor`）は単一固定のまま据え置き

### 19. 検索範囲の拡張
- **症状**: ソース管理画面の検索バーがプリセットのみフィルタし、手動追加ソースは検索無視で常時表示
- **対応**: ✅ 完了（PR #63, 2026-04-21）
  - `manualSources` を `searchText` でフィルタ（`name` と `siteURL.host` を対象）
  - 記事タイトル・要約への拡張は別スコープ（FeedViewへの新機能）として後日対応

---

## 着手順の推奨

コスパ（影響度 ÷ 実装コスト）順:

1. **#3 ソース管理の非対称性解消** — 1-2箇所修正、UX向上効果大
2. **#4 「すべて初期化」の取りこぼし修正** — リスク回避、変更小
3. **#1 AI再生成機能** — ユーザー価値高、AIProcessor呼び出し追加
4. **#11 スキップ即時undo** — 既存スナックバーパターン流用、軽量
5. **#2 スコア安定性向上** — 影響範囲広いので慎重に
6. **#5 CloudKit透明性** — 設計議論が要る、後回しでも可

---

## メモ

- このドキュメントは2026-04-20時点のレビュー結果
- 各項目は仕様変更を伴うものもあるため、着手前に方向性を再確認推奨
- 実装後はこのファイルを更新（チェック or 削除）

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

### 43. 「お気に入り」と「閲覧履歴」モードのセマンティクス曖昧
- `isFavorite` と `isRead` の逆順という異なる軸を並列表示
- 「保存済み」に名称統一、または4モード目に「アーカイブ」追加

### 44. Live Activities / Widget 未対応
- iOSホーム画面ウィジェット、ロック画面ウィジェットなし
- 「ロック画面に最新トレンド1件」程度なら低コストで習慣化に効く

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
5. **#20 macOS keyboard/menu** — macOS が「アプリらしく」なる
6. **#23 visionOS hover/タップ拡大** — visionOS が「拡大版iPad」を脱する
7. **#44 Widget実装** — 習慣化に直結

**長期（中期完了後）**:
8. **#35 Discovery提案理由** — 強みの可視化
9. **#21 macOS スワイプ代替** — 細部の磨き
10. **#34 スコア説明** — 信頼性向上
