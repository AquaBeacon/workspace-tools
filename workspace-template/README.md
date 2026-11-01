# AquaBeacon OSS 開発ワークスペース

水中位置推定・マッピングの設計、ファームウェア、解析と開発ツールをプロジェクト単位で管理します。各行のディレクトリが独立したGitリポジトリです。

## プロジェクト一覧

| リポジトリ | 内容 | 開発手順 |
| --- | --- | --- |
| [obsidian](obsidian/README.md) | Obsidian共有知識・索引・テンプレート | [開発ガイド](obsidian/DEVELOPMENT.md) |
| [docs](docs/README.md) | システム仕様・設計文書 | [開発ガイド](docs/DEVELOPMENT.md) |
| [hardware](hardware/README.md) | 回路図・PCB・製造ツール | [開発ガイド](hardware/DEVELOPMENT.md) |
| [mechanical](mechanical/README.md) | 筐体・機構・印刷一式 | [開発ガイド](mechanical/DEVELOPMENT.md) |
| [firmware](firmware/README.md) | 親機・子機メイン基板ファームウェア | [開発ガイド](firmware/DEVELOPMENT.md) |
| [firmware-experiments](firmware-experiments/README.md) | 実験で使用した親機・子機・Spresense統合コード | [仕様・操作](firmware-experiments/docs/spec.md) |
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
| [aquabeacon.github.io](aquabeacon.github.io/README.md) | 紹介サイト・手法・研究結果・操作できる写真付き水中マップ | [開発ガイド](aquabeacon.github.io/DEVELOPMENT.md) |
| [organization](organization/README.md) | Organizationプロフィール・参加手順 | [開発ガイド](organization/DEVELOPMENT.md) |
| [workspace-tools](workspace-tools/README.md) | リポジトリ台帳・開発ワークスペース管理 | [開発ガイド](workspace-tools/DEVELOPMENT.md) |

## Obsidianで知識をためる

[知識のホーム](obsidian/knowledge/ホーム.md)に分野別の索引、出典付き知識、一覧、関係図を用意しています。[利用方法](obsidian/knowledge/使い方.md)を参照してください。

```sh
python workspace-tools/obsidian.py configure
python workspace-tools/obsidian.py check
```

Obsidianでこの親フォルダ全体を保管庫として開きます。新しいメモ・日誌・添付はGit除外の `obsidian/knowledge/private/` に保存されます。共有する知識は `obsidian/knowledge/notes/` で管理します。構成は[維持方法](docs/maintainer/obsidian.md)を参照してください。

## 開発手順

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

2026-10-16、対象17リポジトリを [AquaBeacon Organization](https://github.com/orgs/AquaBeacon/repositories) にpublicで公開しました。`habatan-game` は対象外です。公開先と取得手順は [workspace-tools](workspace-tools/README.md) を参照してください。新設15件は公開対象だけの初期履歴を持ち、移行前の開発履歴と手元専用データはローカルに保管しています。
