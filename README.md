# FilterAssets

FilterKit 用の WebKit Content Rule List JSON 資産を配布する Swift Package。

このパッケージには AdGuard Filters と EasyList 由来の GPL-3.0-only フィルターを同梱する。
生成済み JSON は `Sources/FilterAssets/Resources/AdBlock/` に置く。

## 対応ソース

- [`manifest.json`](manifest.json): パッケージ概要、採用 upstream、再生成手順への対応情報
- [`filter-sources.json`](filter-sources.json): upstream URL、commit、取得日時、採用 directory、output prefix
- [`build-info.json`](build-info.json): generator 情報、source commit、出力ファイル一覧、sha256
- [`checksums.sha256`](checksums.sha256): Content Rule List、BlockerKit user script、user script manifest の sha256
- [`reports/conversion-report.json`](reports/conversion-report.json): 変換結果の集約
- [`reports/runtime/`](reports/runtime/): profile 単位に統合した BlockerKit runtime の入力 config、rule 件数、artifact checksum
- [`reports/unsupported-rules.json`](reports/unsupported-rules.json): 未対応 rule の集約
- [`reports/dropped-rules.json`](reports/dropped-rules.json): WebKit 検証などで除外された rule の集約
- [`reports/blockerkit/`](reports/blockerkit/): BlockerKit の入力ファイル別詳細レポート

この commit は [`manifest.json`](manifest.json) の `package.version` と同名の tag / GitHub Release で不変に保存する。
Release asset には、`filter-sources.json` に記録した commit と同じ AdGuard Filters / EasyList source archive を添付する。

## 再生成

macOS 13 以降と Swift 5.9 以降があれば、private repository へのアクセスや認証情報なしで再生成できる。
[`filter-sources.json`](filter-sources.json) に固定された upstream commit と、[`Tools/Reproducer/Package.resolved`](Tools/Reproducer/Package.resolved) に固定された BlockerKitSDK を使用する。
`reproduce.sh` は変換後 JSON を検査し、ドメイン制約のない `url-filter: ".*#"` の block rule があれば失敗する。

```sh
./Scripts/reproduce.sh
./Scripts/verify.sh
```

`reproduce.sh` は upstream archive の取得、directory 選択、変換、WebKit Content Rule List のコンパイル、レポートと checksum の生成を一括実行する。
生成ファイル名は `ContentRuleList-<output-prefix>_<source-file>[_chunk_NNN].json` に揃えている。
`BlockerKitUserScript-all-default.js` は `adguard_base`、`adguard_japanese`、EasyList、EasyList Adult の runtime config を入力ファイル名順に統合した1本の script で、注入条件は `documentStart`、全 frame、page content world とする。
downstream は [`BlockerKitUserScriptManifest.json`](Sources/FilterAssets/Resources/AdBlock/BlockerKitUserScriptManifest.json) から profile ID、ファイル名、注入条件を読み取り、同じ page に複数 profile の runtime script を同時注入しない。
`verify.sh` は再生成物を公開中の `checksums.sha256` と照合し、user script manifest の schema、対応ファイル、checksum、runtime rule を持つ全入力 config の収録完全性も検証する。

## ライセンスと除外

ライセンス全文は [`LICENSE`](LICENSE)、第三者表記は [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) を参照する。
EasyList は repository の dual license から GPLv3 側を選択して配布する。
配布物と対応ソースは同じ GitHub Release から取得でき、配布期間中は削除しない。

`FilterPrivateAssets` の独自ルールはこのパッケージに含めない。
AdGuard MobileFilter / `adguard_mobile` 由来の生成物も含めない。
