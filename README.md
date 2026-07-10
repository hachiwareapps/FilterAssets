# FilterAssets

FilterKit 用の WebKit Content Rule List JSON 資産を配布する Swift Package。

このパッケージには AdGuard Filters と EasyList 由来の GPL-3.0-only フィルターを同梱する。
生成済み JSON は `Sources/FilterAssets/Resources/AdBlock/` に置く。

## 対応ソース

- [`manifest.json`](manifest.json): パッケージ概要、採用 upstream、再生成手順への対応情報
- [`filter-sources.json`](filter-sources.json): upstream URL、commit、取得日時、採用 directory、output prefix
- [`build-info.json`](build-info.json): generator 情報、source commit、出力ファイル一覧、sha256
- [`checksums.sha256`](checksums.sha256): `Sources/FilterAssets/Resources/AdBlock/ContentRuleList-*.json` の sha256
- [`reports/conversion-report.json`](reports/conversion-report.json): 変換結果の集約
- [`reports/unsupported-rules.json`](reports/unsupported-rules.json): 未対応 rule の集約
- [`reports/dropped-rules.json`](reports/dropped-rules.json): WebKit 検証などで除外された rule の集約
- [`reports/blockerkit/`](reports/blockerkit/): BlockerKit の入力ファイル別詳細レポート

## 再生成

[`filter-sources.json`](filter-sources.json) に記録された upstream commit と directory を取得し、公開されている [BlockerKitSDK](https://github.com/hachiwareapps/BlockerKitSDK) の `BlockerKitCompiler` で同じ output prefix を使って変換する。
生成ファイル名は `ContentRuleList-<output-prefix>_<source-file>[_chunk_NNN].json` に揃えている。

再生成した JSON は `checksums.sha256` と照合する。

`FilterAssetsUpdater` は内部更新と release orchestration のための非公開リポジトリであり、公開再生成の入口は `filter-sources.json` と `BlockerKitSDK` で説明する。

## ライセンスと除外

ライセンス全文は [`LICENSE`](LICENSE)、第三者表記は [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) を参照する。
EasyList は repository の dual license から GPLv3 側を選択して配布する。

`FilterPrivateAssets` の独自ルールはこのパッケージに含めない。
AdGuard MobileFilter / `adguard_mobile` 由来の生成物も含めない。
