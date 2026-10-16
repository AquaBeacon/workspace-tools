# AquaBeacon OSS 開発ワークスペース

水中位置推定・マッピングの設計、ファームウェア、解析と開発ツールをプロジェクト単位で管理します。各行のディレクトリが独立したGitリポジトリです。

## プロジェクト一覧

| リポジトリ | 内容 | 開発手順 |
| --- | --- | --- |
| [docs](docs/README.md) | システム仕様・設計文書 | [開発ガイド](docs/DEVELOPMENT.md) |
| [hardware](hardware/README.md) | 回路図・PCB・製造ツール | [開発ガイド](hardware/DEVELOPMENT.md) |
| [mechanical](mechanical/README.md) | 筐体・機構・印刷一式 | [開発ガイド](mechanical/DEVELOPMENT.md) |
| [firmware](firmware/README.md) | 親機・子機メイン基板ファームウェア | [開発ガイド](firmware/DEVELOPMENT.md) |
| [acoustic-tests](acoustic-tests/README.md) | TD04A送受信・波形・同期試験 | [開発ガイド](acoustic-tests/DEVELOPMENT.md) |
| [spresense-imu](spresense-imu/README.md) | SPRESENSE IMUロガー・姿勢表示 | [開発ガイド](spresense-imu/DEVELOPMENT.md) |
| [gnss-tools](gnss-tools/README.md) | NEO-F9P受信機・RTK/PPK検証 | [開発ガイド](gnss-tools/DEVELOPMENT.md) |
| [dji-telemetry](dji-telemetry/README.md) | DJI動画メタデータ抽出 | [開発ガイド](dji-telemetry/DEVELOPMENT.md) |
| [aquabeacon-analysis](aquabeacon-analysis/README.md) | 実験データ解析・位置推定・可視化 | [開発ガイド](aquabeacon-analysis/DEVELOPMENT.md) |
| [aquabeacon-sim](aquabeacon-sim/README.md) | 真値付き測位・マッピングシミュレーション | [開発ガイド](aquabeacon-sim/DEVELOPMENT.md) |
| [topopt](topopt/README.md) | 造形用トポロジー最適化・構造解析 | [開発ガイド](topopt/DEVELOPMENT.md) |
| [bambu-tools](bambu-tools/README.md) | Bambuプリンタ・スライス連携 | [開発ガイド](bambu-tools/DEVELOPMENT.md) |
| [acoustic-circuits](acoustic-circuits/README.md) | 初期音響回路の設計資料 | [開発ガイド](acoustic-circuits/DEVELOPMENT.md) |
| [assets](assets/README.md) | ロゴ・説明図・紹介映像 | [開発ガイド](assets/DEVELOPMENT.md) |
| [aquabeacon.github.io](aquabeacon.github.io/README.md) | 公開紹介サイト | [開発ガイド](aquabeacon.github.io/DEVELOPMENT.md) |
| [organization](organization/README.md) | Organizationプロフィール・参加手順 | [開発ガイド](organization/DEVELOPMENT.md) |
| [workspace-tools](workspace-tools/README.md) | リポジトリ台帳・開発ワークスペース管理 | [開発ガイド](workspace-tools/DEVELOPMENT.md) |

## 開発を始める

1. `AquaBeacon.code-workspace` をVS Codeで開くか、目的のリポジトリを単独で開きます。
2. そのリポジトリの `DEVELOPMENT.md` に従い、依存を導入します。
3. 作業したリポジトリの中でGitの差分を確認します。親フォルダ一括のcommit/pushは行いません。

```sh
python workspace-tools/workspace.py list
python workspace-tools/workspace.py check
python workspace-tools/workspace.py audit --output .local/publication-audit.json
```

[移行記録・構成方針](docs/maintainer/migration.md)に旧名との対応、データの扱い、検証結果を記載しています。移動前のパスは既存ツールのためのジャンクションとして残しており、実体はこのワークスペースに集約済みです。

## ライセンス・公開状態

自作部分は **Apache License 2.0**。各リポジトリにLICENSE、NOTICE、THIRD_PARTY.mdを置いています。SDK・フォント・メーカー資料・キャラクターなど第三者の条件は保持します。

この整理はローカルの開発構成です。既存のリモートと履歴を維持し、新しいGitHubリポジトリの作成・push・公開設定の変更はしていません。紹介サイトの既存運用は[サイトのREADME](aquabeacon.github.io/README.md)を参照してください。
