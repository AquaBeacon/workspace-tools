# workspace-tools

リポジトリ台帳・開発ワークスペース管理。

Python標準ライブラリとGitを使用します。python workspace.py list / check / audit で構成と公開候補を確認します。autoresume/ は既存のローカル自動化ツールです。

- [workspace.py](workspace.py)
- [repositories.json](repositories.json)

## 開発とライセンス

`repositories.json` がプロジェクト構成の台帳です。横断開発用の親ディレクトリ自体はGit管理せず、入口文書の正本は `workspace-template/` に保管します。

```sh
python workspace.py list
python workspace.py configure
python workspace.py check
python workspace.py audit --output ../.local/publication-audit.json
```

`configure` は親ディレクトリのREADME・AGENTS・.gitignore・AquaBeacon.code-workspaceだけを再生成します。プロジェクトのclone・初期化・リモート変更・commit・pushは行いません。各公開リポジトリのURLは下表と `repositories.json` に記載しています。

`check` は全リポジトリの配置・入口・ライセンスを確認します。台帳の `history_scope: local_archive` は移行前履歴が保守者の手元だけにあることを示し、公開cloneではその履歴を要求しません。`audit` は現在の追跡ファイルとignore対象外の未追跡ファイルを読み取ります。全履歴の秘密情報検査や第三者の配布許諾の確認を代替しません。両コマンドとも問題検出時は終了コード1です。

## 新しい環境で全体を取得する

Python 3、Git、Git LFSを導入し、空の親フォルダで次を実行します。CAD・映像を含む全体のLFSデータは約4.5 GiBです。必要なプロジェクトだけを下表からcloneして開発することもできます。

```sh
git lfs install
git clone https://github.com/AquaBeacon/workspace-tools.git
```

続いて親フォルダでPythonを起動し、次を実行します。既存フォルダは上書きしません。GitHub上の `.github` はローカルでは `organization` に配置します。

```python
import json
import subprocess
from pathlib import Path

registry = json.loads(Path("workspace-tools/repositories.json").read_text(encoding="utf-8"))
for repo in registry["repositories"]:
    if not Path(repo["name"]).exists():
        subprocess.run(["git", "clone", repo["url"] + ".git", repo["name"]], check=True)
subprocess.run(["python", "workspace-tools/workspace.py", "configure"], check=True)
subprocess.run(["python", "workspace-tools/workspace.py", "check"], check=True)
```

[開発ガイド](DEVELOPMENT.md)にセットアップ・入口・確認方法をまとめています。自作部分は [Apache License 2.0](LICENSE)。[第三者素材・依存の扱い](THIRD_PARTY.md)も参照してください。

## 公開リポジトリ一覧

| リポジトリ | 内容 |
| --- | --- |
| [docs](https://github.com/AquaBeacon/docs) | システム仕様・設計文書 |
| [hardware](https://github.com/AquaBeacon/hardware) | 回路図・PCB・製造ツール |
| [mechanical](https://github.com/AquaBeacon/mechanical) | 筐体・機構・印刷一式 |
| [firmware](https://github.com/AquaBeacon/firmware) | 親機・子機メイン基板ファームウェア |
| [acoustic-tests](https://github.com/AquaBeacon/acoustic-tests) | TD04A送受信・波形・同期試験 |
| [spresense-imu](https://github.com/AquaBeacon/spresense-imu) | SPRESENSE IMUロガー・姿勢表示 |
| [gnss-tools](https://github.com/AquaBeacon/gnss-tools) | NEO-F9P受信機・RTK/PPK検証 |
| [dji-telemetry](https://github.com/AquaBeacon/dji-telemetry) | DJI動画メタデータ抽出 |
| [aquabeacon-analysis](https://github.com/AquaBeacon/aquabeacon-analysis) | 実験データ解析・位置推定・可視化 |
| [aquabeacon-sim](https://github.com/AquaBeacon/aquabeacon-sim) | 真値付き測位・マッピングシミュレーション |
| [topopt](https://github.com/AquaBeacon/topopt) | 造形用トポロジー最適化・構造解析 |
| [bambu-tools](https://github.com/AquaBeacon/bambu-tools) | Bambuプリンタ・スライス連携 |
| [acoustic-circuits](https://github.com/AquaBeacon/acoustic-circuits) | 初期音響回路の設計資料 |
| [assets](https://github.com/AquaBeacon/assets) | ロゴ・説明図・紹介映像 |
| [aquabeacon.github.io](https://github.com/AquaBeacon/aquabeacon.github.io) | 公開紹介サイト |
| [organization](https://github.com/AquaBeacon/.github) | Organizationプロフィール・参加手順 |
| [workspace-tools](https://github.com/AquaBeacon/workspace-tools) | リポジトリ台帳・開発ワークスペース管理 |
