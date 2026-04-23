# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
pnpm dev      # 記事のローカルプレビューを起動 (http://localhost:8000)
pnpm build    # ビルド確認
```

### Submodule 操作

```bash
./scripts/submodule-init.sh                        # clone 後の初期化
./scripts/submodule-update.sh                      # 全 submodule を最新に更新
./scripts/submodule-update.sh <name>               # 指定 submodule だけ更新
./scripts/submodule-status.sh                      # 各 submodule のコミット確認
./scripts/submodule-add.sh <name> [description]    # GitHub repo を新規作成して submodule に追加
```

## 構成

- `articles/` — Zenn 記事 (.md)。各ファイルは YAML frontmatter (`title`, `emoji`, `type`, `topics`, `published`) で始まる。
- `repos/` — 記事に対応するサンプルコードリポジトリ (git submodule)。各 submodule は特定のコミットに固定されている。
- `scripts/` — submodule 操作のショートカットスクリプト。
- `idea/` — 執筆候補の記事アイデア (非公開)。

### 記事と submodule の対応

| 記事ファイル | repos/ |
|-------------|--------|
| react-mini-zustand.md | react-mini-zustand |
| react-mini-valtio.md | react-mini-valtio |
| react-mini-xstate.md | react-mini-xstate |
| react-mini-jotai.md | react-mini-jotai |
| go-minimal-kv-design.md | kv_database |

## 記事を新規作成するとき

```bash
pnpm zenn new:article --slug <slug> --type tech
```

`published: false` で下書き作成され、`published: true` に変更すると公開される。
