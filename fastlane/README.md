fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios upload_metadata

```sh
[bundle exec] fastlane ios upload_metadata
```

メタデータとスクリーンショットをアップロード（バージョン未作成なら作成）

### ios upload_creative_assets

```sh
[bundle exec] fastlane ios upload_creative_assets
```

製品ページのヘッダ・検索結果アセットをアップロードして現在のバージョンに配置（iOS のみ、表示は iOS 27 以降）。画像は `fastlane/creative_assets/<locale>/header_21x9.png`（3840x1646）と `search_3x2.png`（3840x2560）に置く。

### ios upload_metadata_only

```sh
[bundle exec] fastlane ios upload_metadata_only
```

メタデータのみアップロード（バージョン未作成なら作成）

### ios upload_screenshots

```sh
[bundle exec] fastlane ios upload_screenshots
```

スクリーンショットのみアップロード（既存バージョンへ）

### ios download_metadata

```sh
[bundle exec] fastlane ios download_metadata
```

メタデータをダウンロード

----


## Mac

### mac upload_metadata_only

```sh
[bundle exec] fastlane mac upload_metadata_only
```

macOSメタデータをアップロード（バージョン未作成なら作成）

### mac upload_screenshots

```sh
[bundle exec] fastlane mac upload_screenshots
```

macOSスクリーンショットをアップロード（既存バージョンへ）

----


## visionos

### visionos upload_metadata_only

```sh
[bundle exec] fastlane visionos upload_metadata_only
```

visionOSメタデータをアップロード（バージョン未作成なら作成）

### visionos upload_screenshots

```sh
[bundle exec] fastlane visionos upload_screenshots
```

visionOSスクリーンショットをアップロード（既存バージョンへ）

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
