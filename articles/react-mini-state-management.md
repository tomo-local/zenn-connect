---
title: "2026年 Reactの状態管理ライブラリを比較する"
emoji: "🔍"
type: "tech"
topics: ["react", "javascript", "typescript", "frontend", "state"]
published: true
---

## はじめに

はじめまして、tomo-localです！
この記事では、ReactのメジャーなState管理ライブラリーを簡易的に実装することで、仕組みを理解した上で、最適な選択肢の比較・検討を行うための内容をまとめていきたいと思います。

何かしら役に立ててもらえれば幸いです。

各ライブラリーの簡易実装はこちらのシリーズでまとめています。

https://zenn.dev/tomo_local/articles/react-mini-valtio

https://zenn.dev/tomo_local/articles/react-mini-jotai

https://zenn.dev/tomo_local/articles/react-mini-xstate

https://zenn.dev/tomo_local/articles/react-mini-zustand

## 4つのライブラリー、何が違うのか

まず大きな視点で整理すると、4つのうち3つ（Valtio・Jotai・Zustand）は「**値をどう持ち、どう書き換えるか**」の話です。XStateだけが毛色が違って、「**いまどの状態にいるか**」を管理するアプローチを取っています。

| | Valtio | Jotai | XState | Zustand |
|---|---|---|---|---|
| **状態の表現** | 値（何の値か） | 値（何の値か） | 状態名（どこにいるか） | 値（何の値か） |
| **更新の書き方** | `state.count++` | `setCount(n => n + 1)` | `send('INCREMENT')` | `set({ count: n + 1 })` |
| **状態の保持** | Proxy（クロージャ） | WeakMap（Store） | クロージャ（Actor） | クロージャ（Store） |
| **Reactとの同期** | `useSyncExternalStore` | `useReducer` + `useEffect` | `useSyncExternalStore` | `useSyncExternalStore` |

内部実装でいうと、4つともObserverパターン（`Set` でリスナーを管理して変更を通知する）を核にしています。「どんなデータモデルで状態を表現するか」という設計の違いが、APIや適した用途の違いとして表れています。

## 選ぶときに見るべき観点

APIの違いだけでなく、プロジェクトに採用するときに気になる観点も比較してみます。

| | Valtio | Jotai | XState | Zustand |
|---|---|---|---|---|
| **バンドルサイズ** | 約2.6KB | 約2.7KB | 約22KB | 約1KB |
| **学習コスト** | 低 | 低〜中 | 高 | 低 |
| **TypeScript相性** | ◎ | ◎ | ◎ | ○ |
| **再レンダリング制御** | ○（プロパティ追跡） | ◎（atomごとに分離） | △ | ○（セレクタ） |
| **DevTools** | △ | ○（専用あり） | ◎（Viz対応） | ◎（Redux DevTools） |
| **SSR / Next.js** | △（要工夫） | ◎（Provider分離） | ○ | △（要工夫） |

XStateはバンドルサイズが他より大きいですが、状態遷移を図として可視化できる[XState Visualizer](https://stately.ai/viz)が強力です。複雑なフローをチームで共有する場面では特に重宝します。

https://stately.ai/viz

ZustandとValtioはグローバルなモジュールとしてStoreを持つため、SSRではリクエストをまたいで状態が混ざらないよう工夫が必要です。JotaiはProviderで自然にスコープを分離できるので、Next.js (App Router) との相性がよいと思います。

## どれを選ぶか

### Zustand — まず迷ったらこれ

https://zustand.docs.pmnd.rs

シンプルさと実用性のバランスが取れていて、**多くのケースでまず検討する価値があるライブラリー**だと思います。状態とアクションを一か所に定義でき、セレクタで購読範囲も絞れます。

```typescript
const useAuthStore = create<AuthStore>((set) => ({
  user: null,
  login: (user) => set({ user }),
  logout: () => set({ user: null }),
}));

// セレクタでuserだけを購読
const user = useAuthStore((state) => state.user);
```

**向いている場面**
- ユーザー情報・セッション・設定など、アプリ全体で参照するグローバルな状態
- ReduxやContext APIからの移行先として
- 学習コストを抑えて早く動かしたいとき

**注意したい場面**
- 状態の数が増えてatomレベルの細かい再レンダリング制御が必要になってきたとき
- 状態遷移ロジックを型で厳密に管理したいとき

---

### Jotai — 細かく分割したい・SSRを使う

https://jotai.org

状態を `atom` という最小単位に分割して管理します。コンポーネントは自分が使うatomだけを購読するため、**他の状態が変わっても再レンダリングが起きません**。

```typescript
const isModalOpenAtom = atom(false);
const activeTabAtom = atom<'home' | 'settings'>('home');

// 別々のコンポーネントが独立して購読できる
const [isOpen, setIsOpen] = useAtom(isModalOpenAtom);
const [tab, setTab] = useAtom(activeTabAtom);
```

**向いている場面**
- モーダルの開閉・タブ選択など、UIコンポーネント間で共有する細粒度の状態
- 再レンダリングの最適化をしっかりやりたいとき
- Next.js (App Router) でSSR対応が必要なとき

**注意したい場面**
- atom間の依存関係が複雑になりすぎて設計がしんどくなるとき
- 状態遷移のルールを一か所で管理したいとき

---

### XState — 遷移ルールがある複雑なフロー

https://xstate.js.org

他の3つとは根本的にアプローチが違います。「いまどの状態にいるか」を状態名として明示的に管理し、**定義されていないイベントは自動的に無視される**ので「ありえない状態遷移」が型レベルで排除されます。

```typescript
const fetchMachine = createMachine({
  initial: 'idle',
  states: {
    idle:    { on: { FETCH: 'loading' } },
    loading: { on: { RESOLVE: 'success', REJECT: 'error' } },
    success: {},
    error:   { on: { RETRY: 'loading' } },
  },
});

// loading中にFETCHを送っても何も起きない（安全）
send('FETCH'); // idle → loading
send('FETCH'); // loading状態では無視される
```

**向いている場面**
- 多段階フォーム・ウィザード
- データフェッチの状態管理（idle / loading / success / error）
- 認証フローなど「この状態ではこの操作はできない」を型で強制したいとき
- 状態遷移をチームで図として共有・レビューしたいとき

**注意したい場面**
- 単純なカウンターやフラグ管理には過剰になりがち
- バンドルサイズを最小化したいとき

---

### Valtio — ミュータブルに書きたい

https://valtio.dev

`proxy()` でオブジェクトをラップするだけで、通常のJavaScriptオブジェクトを操作する感覚のままリアクティブな更新が動きます。**書き方を変えたくない**場合に自然に使えます。

```typescript
const state = proxy({ user: { address: { city: '' } } });

// ネストしたオブジェクトもそのまま変更できる
state.user.address.city = '東京';
```

**向いている場面**
- ネストが深い設定オブジェクトをミュータブルに操作したいとき
- MobXからの移行先として
- イミュータブルな更新の書き方を避けたいとき

**注意したい場面**
- SSRを使う場合は追加の工夫が必要
- DevToolsによるデバッグを重視するとき

## バンドルサイズの詳細

バンドルサイズは[bundlephobia](https://bundlephobia.com)で確認できます。参考までに2026年4月時点の数値を載せておきます。

| | minified | minified + gzipped |
|---|---|---|
| **Zustand** | 3.3KB | 1.2KB |
| **Valtio** | 8.2KB | 2.6KB |
| **Jotai** | 9.1KB | 2.7KB |
| **XState** (`xstate` + `@xstate/react`) | 約170KB | 約55KB |

Zustandは圧倒的に軽量です。XStateはコア部分だけでもサイズが大きいため、バンドルサイズを気にするプロジェクトでは注意が必要だと思います。

## 周辺ライブラリーの充実度

### Zustand

ミドルウェアが公式パッケージ（`zustand/middleware`）として同梱されており、追加インストールなしで使えます。

- `immer` — ミュータブルな書き方でイミュータブルな更新
- `devtools` — Redux DevToolsとの連携
- `persist` — localStorageへの永続化
- `subscribeWithSelector` — セレクタ付きの外部購読

### Jotai

`jotai/utils` に豊富なユーティリティatomが含まれています。また、TanStack Queryとの公式インテグレーションも充実しています。

- `atomWithStorage` — localStorageと同期するatom
- `atomWithReducer` — reducerパターンのatom
- `atomWithQuery` — TanStack Query連携（`jotai-tanstack-query`）
- `atomWithReset` — リセット可能なatom

### XState

フレームワーク対応が幅広く、React以外でも使えます。ビジュアルエディタも提供されています。

- `@xstate/react` / `@xstate/vue` / `@xstate/svelte` — 各フレームワーク向けバインディング
- [Stately Editor](https://stately.ai/editor) — ブラウザ上で状態遷移図を編集・生成できるGUIツール
- `@xstate/test` — 状態機械からテストケースを自動生成

### Valtio

コアはシンプルですが、`valtio/utils` にいくつか便利なユーティリティが用意されています。

- `proxyWithHistory` — 状態の履歴管理（undo/redo）
- `proxyMap` / `proxySet` — MapやSetをリアクティブに扱う
- `valtio-yjs` — Yjs（リアルタイム共同編集ライブラリー）との同期

## おわりに

最後まで読んでいただきありがとうございました！
この記事がReactの状態管理ライブラリーを選ぶときの参考になれば幸いです。🙇‍♂️
