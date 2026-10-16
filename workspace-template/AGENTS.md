# AquaBeacon OSS ワークスペース

- 各直下プロジェクトが独立したGitリポジトリ。親ディレクトリをGitリポジトリにしない。
- 各プロジェクト内のAGENTS.mdと設計元を優先する。
- `python workspace-tools/workspace.py check` で構成を検証する。
- 構成変更時はworkspace-tools/repositories.json、README、docs/maintainerを同期する。
- 自作部分はApache-2.0。第三者のSDK・素材・ライセンス表示を維持する。
- `.local/`は移行記録とバックアップ。生データ、認証情報、購入台帳は公開しない。
- サイトの配信範囲はaquabeacon.github.io/site/のみ。公開状態をローカル移行と混同しない。
