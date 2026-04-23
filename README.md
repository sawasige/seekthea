# Seekthea

ニュース・テック・ソーシャルのトレンドをRSSで収集し、Apple IntelligenceのAI要約で記事のポイントが一瞬でわかるパーソナルトレンドアグリゲーター。

## 機能

- **幅広いソース** — 14カテゴリ100以上のプリセットから選べる。RSSフィードURLの直接追加も可能
- **AI要約・カテゴリ分類** — Apple Intelligenceがデバイス上で記事を要約・分類
- **3つの読み方** — リーダー / AI要約 / Web を記事ごとに切り替え
- **ソース自動発見** — Google Newsのトレンドから新しいソースを自動提案
- **パーソナライズ** — 閲覧履歴から興味を学習し、各記事に興味度スコアを表示。内訳も確認可能
- **特定ソースで絞り込み** — 気になるソース1つだけを表示、または不要なソースを除外
- **iCloud同期** — お気に入り・既読状態・ソース設定がiPhone・iPad・Macで自動同期

## 対応プラットフォーム

- iPhone / iPad（iOS 26+）
- Mac（macOS 26+）
- Apple Vision Pro（visionOS 26+）

## 要件

- AI要約にはApple Intelligence対応デバイス（iPhone 15 Pro以降）が必要
- AI非対応デバイスでは要約・分類なしで動作

## リンク

- [ランディングページ](https://sawasige.github.io/seekthea/)
- [プライバシーポリシー](https://sawasige.github.io/seekthea/privacy.html)
- [利用規約](https://sawasige.github.io/seekthea/terms.html)
- [サポート](https://sawasige.github.io/seekthea/support.html)

## リリース手順

### 1. バージョン更新

Xcodeで `MARKETING_VERSION` を更新する。

### 2. メタデータ更新

```bash
# リリースノートを編集
vi fastlane/metadata/ja/release_notes.txt

# メタデータをApp Store Connectにアップロード
bundle exec fastlane ios upload_metadata_only
bundle exec fastlane mac upload_metadata_only
bundle exec fastlane visionos upload_metadata_only
```

### 3. スクリーンショット更新（必要な場合）

```bash
# スクショを差し替えた後
bundle exec fastlane ios upload_screenshots
bundle exec fastlane mac upload_screenshots
bundle exec fastlane visionos upload_screenshots
```

### 4. ビルド & TestFlight

Xcode Cloudで手動ビルドを実行。ビルド番号は `ci_post_clone.sh` で自動設定される。

### 5. 審査提出

App Store Connectで各プラットフォーム（iOS / macOS / visionOS）のビルドを選択し、審査に提出。

## ライセンス

All rights reserved.
