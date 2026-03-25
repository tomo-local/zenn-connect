---
title: "Reactの状態管理ライブラリを自作して仕組みを比較する"
emoji: "🔍"
type: "tech"
topics: ["react", "javascript", "typescript", "frontend", "state"]
published: false
---

## はじめに

このシリーズでは、ReactのメジャーなState管理ライブラリの簡易版を自作することで、それぞれの内部の仕組みを探ってきました。

- [Valtio](/tomo_local/articles/react-mini-valtio) — Proxyによるミュータブルな状態管理
- [Jotai](/tomo_local/articles/react-mini-jotai) — atomを単位としたアトミックな状態管理
- [XState](/tomo_local/articles/react-mini-xstate) — 有限状態機械による状態遷移の管理
- [Zustand](/tomo_local/articles/react-mini-zustand) — セレクタ付きシングルStoreによる状態管理

この記事では、4つのライブラリの実装上の共通点・相違点を整理し、「どんな場面でどれを選ぶか」をまとめます。

## 4つのライブラリの概要

### Valtio — 「書き方を変えない」状態管理

`proxy()` でオブジェクトをラップするだけで、`state.count++` のような**ミュータブルな書き方のまま**リアクティブな更新が動きます。JavaScriptの `Proxy` APIが変更を検知してリスナーへ通知する仕組みです。

```typescript
const state = proxy({ count: 0 });
state.count++; // これだけで再レンダリングされる
```

### Jotai — 「必要なものだけ」を購読する

`atom` という小さな単位に状態を分割して管理します。コンポーネントは自分が使う `atom` だけを購読するため、無関係な状態変化では再レンダリングされません。実際の値はコンポーネントツリー外の `Store`（`WeakMap`）が管理します。

```typescript
const countAtom = atom(0);
const [count, setCount] = useAtom(countAtom); // countだけを購読
```

### XState — 「いまどの状態にいるか」を明示する

状態を排他的な「状態名」のひとつとして表現する**有限状態機械**のアプローチです。定義されていないイベントは自動的に無視されるため、「ありえない状態」や不正な状態遷移を型レベルで排除できます。

```typescript
const fetchMachine = createMachine({
  initial: 'idle',
  states: {
    idle:    { on: { FETCH: 'loading' } },
    loading: { on: { RESOLVE: 'success', REJECT: 'error' } },
  },
});
const [state, send] = useMachine(fetchMachine);
```

### Zustand — 「状態とアクションをまとめて」管理する

`create` に渡す関数の中に**状態と更新アクションを一緒に定義**できます。セレクタ関数を渡すことで必要なスライスだけを購読でき、Contextなしでグローバルな状態管理が完結します。

```typescript
const useStore = create((set) => ({
  count: 0,
  increment: () => set((s) => ({ count: s.count + 1 })),
}));
const count = useStore((state) => state.count); // countだけを購読
```

## 実装の比較

### コアAPIの比較

| | Valtio | Jotai | XState | Zustand |
|---|---|---|---|---|
| **状態の保持** | `Proxy`（クロージャ） | `WeakMap`（Store） | クロージャ（Actor） | クロージャ（Store） |
| **変更の通知** | `Set`（listeners） | `Set`（listeners） | `Set`（listeners） | `Set`（listeners） |
| **Reactとの同期** | `useSyncExternalStore` | `useReducer` + `useEffect` | `useSyncExternalStore` | `useSyncExternalStore` |

4つのライブラリはすべて、**Observerパターン**（`Set` でリスナーを管理し変更時に通知する）を核としています。Reactとの同期方法だけが異なります。

### 状態のデータモデルの比較

| | Valtio | Jotai | XState | Zustand |
|---|---|---|---|---|
| **データモデル** | ミュータブルなオブジェクト | イミュータブルなatom | 有限状態機械 | イミュータブルなオブジェクト |
| **状態の表現** | 値（何の値か） | 値（何の値か） | 状態名（どこにいるか） | 値（何の値か） |
| **更新の書き方** | `state.count++` | `setCount(n => n + 1)` | `send('INCREMENT')` | `set({ count: n + 1 })` |

XStateだけが「値」ではなく「どの状態にいるか」を管理するという点で、他の3つとは根本的にアプローチが異なります。

## どれを選ぶか

### Valtio が向いている場面

フォームや設定画面のように、**ネストが深いオブジェクトを直感的に操作**したい場面。ミュータブルな書き方を好む、または既存のコードのスタイルに合わせたい場合に有効です。

```typescript
// ネストしたオブジェクトも直接変更できる（本家のみ）
state.user.address.city = '東京';
```

### Jotai が向いている場面

UIの細かいパーツ（モーダルの開閉、タブの選択状態など）を**コンポーネントをまたいで共有**したい場面。状態を細かく分割して、必要なコンポーネントだけが再レンダリングされるようにしたい場合に向いています。

```typescript
const isModalOpenAtom = atom(false);
const activeTabAtom = atom('home');
// それぞれのatomを独立して購読できる
```

### XState が向いている場面

ウィザード、データフェッチ、認証フローのように**明確な状態遷移を持つ複雑なUI**。「この状態のときにこの操作はできない」というルールを型で強制したい場面に最適です。

```typescript
// loading中にFETCHを送っても何も起きない（安全）
send('FETCH'); // idle → loading
send('FETCH'); // loading状態では無視される
```

### Zustand が向いている場面

ユーザー情報やカート内容のような**アプリ全体で共有するグローバルな状態**を、シンプルなAPIで管理したい場面。ReduxほどのボイラープレートなしにReducer的な設計を実現したい場合に向いています。

```typescript
// 状態とアクションが一箇所にまとまっている
const useAuthStore = create((set) => ({
  user: null,
  login: (user) => set({ user }),
  logout: () => set({ user: null }),
}));
```

## 実装してみた感想

### Valtio・Jotai — シンプルに「値の読み書き」だけを考えられた

ValtioとJotaiは、簡易実装する際に**「値をどう保持して、どう取り出すか」だけに集中できる**シンプルさがありました。

Valtioは `Proxy` の `set` トラップで変更を検知して通知するだけ、JotaiはWeakMapに値を保存して `get` / `set` で読み書きするだけ。どちらも「値の入れ物」としての責務が明確で、型の設計もストレートに書けました。

### XState・Zustand — TypeScriptの型設計と更新ロジックに苦労した

XStateとZustandは、同じ状態管理でも実装の難易度が一段上がりました。

**XStateの難しさ**は、状態名（`S`）とイベント名（`E`）という2つのジェネリクスを扱う型設計にあります。「状態ごとにどのイベントが有効か」という構造を型で表現するため、`Record<S, StateConfig<E>>` のような入れ子の型定義が必要で、TypeScriptの推論を正しく効かせるための工夫が求められました。

**Zustandの難しさ**は、`setState` の更新ロジックにあります。「関数形式（`prev => next`）とオブジェクト形式（`{ count: 1 }`）の両方を受け付け、オブジェクトの場合は既存の状態にマージする」という挙動を型安全に実装するのが思ったより複雑でした。また `create` が返す値が「Hookであり、同時にStoreのAPIも持つ」という二重の役割を持つため、型の整合性を取るのにも手間がかかりました。

## まとめ

4つのライブラリの実装を通じて見えてきた共通点は、**すべてObserverパターンをベースに `useSyncExternalStore`（または同等の仕組み）でReactと橋渡しをしている**という点です。その上で、「どんなデータモデルで状態を表現するか」「どうReactと同期するか」の設計が異なります。

ライブラリを選ぶ際は「どんなAPIで書きたいか」よりも、「**管理したい状態の性質**」に注目するのが良いと思います。

| 管理したい状態の性質 | 向いているライブラリ |
|---|---|
| ミュータブルに操作したいオブジェクト | Valtio |
| コンポーネント間で共有する細粒度の状態 | Jotai |
| 遷移ルールが明確なフロー・ステップ | XState |
| アプリ全体で共有するグローバルな状態 | Zustand |
