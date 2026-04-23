## Zenn Connect

Zenn の記事と、対応するサンプルコードのリポジトリを一元管理するリポジトリです。

- 記事: https://zenn.dev/tomo_local

---

## フォルダー構成

```
zenn-connect/
├── articles/          # Zenn 記事 (.md)
├── books/             # Zenn 本
├── repos/             # 記事に対応するサンプルコード (git submodule)
│   ├── react-mini-zustand/
│   ├── react-mini-valtio/
│   ├── react-mini-xstate/
│   ├── react-mini-jotai/
│   └── kv_database/
└── scripts/           # よく使うコマンドのショートカット
```

### 記事とリポジトリの対応

| 記事 | リポジトリ |
|------|-----------|
| [Zustandを自作して仕組みを理解する](articles/react-mini-zustand.md) | repos/react-mini-zustand |
| [Valtioを自作して仕組みを理解する](articles/react-mini-valtio.md) | repos/react-mini-valtio |
| [XStateを自作して仕組みを理解する](articles/react-mini-xstate.md) | repos/react-mini-xstate |
| [Jotaiを自作して仕組みを理解する](articles/react-mini-jotai.md) | repos/react-mini-jotai |
| [GoでシンプルなKVデータベースを自作する](articles/go-minimal-kv-design.md) | repos/kv_database |

---

## scripts/

| スクリプト | 説明 |
|-----------|------|
| `scripts/submodule-init.sh` | clone 後に submodule を初期化・取得する |
| `scripts/submodule-update.sh` | すべての submodule を最新コミットに更新する |
| `scripts/submodule-update.sh <name>` | 指定した submodule だけ更新する (例: `react-mini-zustand`) |
| `scripts/submodule-status.sh` | 各 submodule の現在のコミットを確認する |

---

## セットアップ

```bash
# clone 時に submodule も一緒に取得する
git clone --recurse-submodules https://github.com/tomo-local/zenn-connect.git

# すでに clone 済みの場合
./scripts/submodule-init.sh
```

## 記事のプレビュー

```bash
pnpm dev
```
