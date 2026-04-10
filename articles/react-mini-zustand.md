---
title: "Reactの状態管理ライブラリ「Zustand」を自作して仕組みを理解する"
emoji: "🐻"
type: "tech"
topics: ["react", "zustand", "javascript", "typescript", "frontend", "state"]
published: true
---

## はじめに

[Valtio](/tomo_local/articles/react-mini-valtio)・[Jotai](/tomo_local/articles/react-mini-jotai)・[XState](/tomo_local/articles/react-mini-xstate) に続く本シリーズ4回目です。今回はReactの状態管理ライブラリの中でも特に人気の高い「Zustand」を自作してみます。

Zustandは「シンプルなAPIでグローバルな状態を管理できる」ライブラリです。ReduxのようにひとつのStoreで状態を一元管理しつつも、ボイラープレートが少なく、**セレクタ（selector）を使って必要なスライスだけを購読できる**点が特徴です。

この記事では、Zustandのコアコンセプトを理解するために、その簡易版を自作して、どのようにしてStoreが状態を管理し、Reactコンポーネントと同期しているのかを探ります。

## 標準のState管理との比較

React標準の `useState` や `useContext` には、いくつかの設計上の制約や課題があります。

### 1. useStateのスコープ問題

`useState` はコンポーネントローカルな状態には最適ですが、複数コンポーネント間で状態を共有するには `useContext` と組み合わせる必要があります。

```javascript
// 状態をコンポーネント間で共有するにはContextが必要
const CountContext = createContext(0);
```

### 2. useContextの再レンダリング問題

`Context` を使うと、コンテキスト内の**一部の値**が更新されただけで、そのコンテキストを購読している**すべてのコンポーネント**が再レンダリングされてしまいます。

```javascript
const AppContext = createContext({ count: 0, text: 'Hello' });

// countだけ変わっても、textしか使っていないコンポーネントも再レンダリングされる
```

Zustandはこれらの問題を、グローバルなStoreとセレクタという仕組みで解決します。

## Zustandの仕組み（コンセプト）

Zustandのポイントは、**「Storeの作成」と「React Hookとしての利用」を `create` ひとつで完結させる**点です。

1. **createStore（バニラStore）**: 状態・更新関数・購読者を管理するコアオブジェクト。`getState` / `setState` / `subscribe` のAPIを持つ。Reactに依存しない。
2. **create（React バインディング）**: `createStore` をラップして `useSyncExternalStore` でReactと同期するHookを返す。セレクタを受け取り、必要なスライスだけを購読できる。

`createStore` はReactを知らない純粋な状態コンテナで、`create` がReactの橋渡しをします。

## 簡易版Zustandの実装

それでは、TypeScriptを使って `mini-zustand` を実装してみましょう。

:::message
**今回の簡易版の制約**
- **Shallow比較**: セレクタが返すオブジェクトの浅い比較（`shallow`）は実装しません。本家ZustandはObject同士の比較に `shallow` ユーティリティを提供しています。
- **Middleware**: `immer` ミドルウェアや `persist` ミドルウェアなどの拡張機構は実装しません。
- **`useShallow`**: オブジェクトを返すセレクタでの再レンダリング最適化Hookは実装しません。
:::

### Step 1: `createStore` — バニラStoreを作る

最初に作るのは、Reactに依存しないコアのStoreです。**状態値・更新関数・購読者**の3つを管理します。

> 📎 本家Zustandの実装: [createStore - src/vanilla.ts](https://github.com/pmndrs/zustand/blob/main/src/vanilla.ts)

```typescript
type SetState<T> = (
  partial: T | Partial<T> | ((state: T) => T | Partial<T>)
) => void;
type GetState<T> = () => T;
type Listener = () => void;

export type StoreApi<T> = {
  getState: GetState<T>;
  setState: SetState<T>;
  subscribe: (listener: Listener) => () => void;
};

type StateCreator<T> = (set: SetState<T>, get: GetState<T>) => T;

export function createStore<T extends object>(
  initializer: StateCreator<T>
): StoreApi<T> {
  let state: T;
  const listeners = new Set<Listener>();

  const setState: SetState<T> = (partial) => {
    // 関数形式（prev => next）にも対応
    const nextPartial =
      typeof partial === 'function'
        ? (partial as (state: T) => T | Partial<T>)(state)
        : partial;

    // オブジェクトなら既存の状態にマージ、プリミティブなら置き換え
    const nextState =
      typeof nextPartial === 'object' && nextPartial !== null
        ? Object.assign({}, state, nextPartial)
        : (nextPartial as T);

    if (Object.is(state, nextState)) return; // 変化なければ通知しない
    state = nextState;
    listeners.forEach((l) => l());
  };

  const getState: GetState<T> = () => state;

  const subscribe = (listener: Listener): (() => void) => {
    listeners.add(listener);
    return () => listeners.delete(listener);
  };

  // initializerを実行して初期状態を生成
  state = initializer(setState, getState);

  return { getState, setState, subscribe };
}
```

**`setState` がオブジェクトをマージする理由**

Zustandの `setState` は `useState` の `setState` に似ていますが、オブジェクトの場合は**既存の状態に自動でマージ**します。これにより、一部のプロパティだけを更新する際に `{ ...prev, count: prev.count + 1 }` のようなスプレッドが不要になります。

```typescript
// マージ動作の例
const store = createStore(() => ({ count: 0, text: 'Hello' }));
store.setState({ count: 1 }); // { count: 1, text: 'Hello' } になる（textはそのまま）
```

### Step 2: `create` — React Hookとして使えるようにする

次に、`createStore` をラップして、コンポーネントから直接使える `useStore` Hookを返す `create` 関数を実装します。**セレクタ**を受け取ることで、Storeの一部だけを購読できるのがポイントです。

> 📎 本家Zustandの実装: [create - src/react.ts](https://github.com/pmndrs/zustand/blob/main/src/react.ts)

```typescript
import { useSyncExternalStore } from 'react';
import { createStore, StoreApi, SetState } from './store';

type StateCreator<T> = (set: SetState<T>, get: () => T) => T;

export function create<T extends object>(initializer: StateCreator<T>) {
  const api = createStore(initializer);

  // セレクタなし: ストア全体を返す
  function useStore(): T;
  // セレクタあり: 選択したスライスを返す
  function useStore<U>(selector: (state: T) => U): U;
  function useStore<U>(selector?: (state: T) => U): T | U {
    return useSyncExternalStore(
      api.subscribe,
      selector
        ? () => selector(api.getState())
        : api.getState,
    );
  }

  // StoreのAPIをhookに直接生やして useStore.getState() などで使えるようにする
  return Object.assign(useStore, api);
}
```

**セレクタで再レンダリングを最適化する仕組み**

`useSyncExternalStore` は `getSnapshot` の返り値を `===` で比較し、変化がなければ再レンダリングをスキップします。

```typescript
// セレクタなし: storeの全状態を返す → どのプロパティが変わっても再レンダリング
const { count, text } = useCounterStore();

// セレクタあり: countだけを返す → countが変わった時だけ再レンダリング
const count = useCounterStore((state) => state.count);
```

セレクタがプリミティブ（`number`, `string` など）を返す場合は `===` での比較が正しく機能します。オブジェクトや配列を返す場合は毎回新しい参照になってしまうため、本家Zustandは `useShallow` という浅い比較Hookを提供しています（今回の簡易版には含みません）。

## 実際に使ってみる

実装した `mini-zustand` を使って、カウンターアプリを作ってみましょう。

まずStoreを定義します。`create` に渡す関数の中に**状態と更新アクションをまとめて書ける**のがZustandの大きな特徴です。

```typescript
import { create } from './mini-zustand/create';

type CounterStore = {
  count: number;
  text: string;
  increment: () => void;
  decrement: () => void;
  setText: (text: string) => void;
};

export const useCounterStore = create<CounterStore>((set) => ({
  count: 0,
  text: 'Hello',
  increment: () => set((state) => ({ count: state.count + 1 })),
  decrement: () => set((state) => ({ count: state.count - 1 })),
  setText: (text) => set({ text }),
}));
```

次に、このStoreを使ったReactコンポーネントを実装します。

```tsx
import React from 'react';
import { useCounterStore } from './store';

const Counter = () => {
  // countだけを購読 → textが変わっても再レンダリングされない
  const count = useCounterStore((state) => state.count);
  const increment = useCounterStore((state) => state.increment);
  const decrement = useCounterStore((state) => state.decrement);

  return (
    <div>
      <p>Count: {count}</p>
      <button onClick={increment}>+1</button>
      <button onClick={decrement}>-1</button>
    </div>
  );
};

const TextInput = () => {
  // textだけを購読 → countが変わっても再レンダリングされない
  const text = useCounterStore((state) => state.text);
  const setText = useCounterStore((state) => state.setText);

  return (
    <input
      value={text}
      onChange={(e) => setText(e.target.value)}
    />
  );
};

export default function App() {
  return (
    <div>
      <Counter />
      <TextInput />
    </div>
  );
}
```

`Counter` は `count` のみ、`TextInput` は `text` のみを購読しています。そのため `count` が変化しても `TextInput` は再レンダリングされず、逆も同様です。

また、`create` が返す `useCounterStore` にはStoreのAPIも直接アタッチされているため、コンポーネントの外からも状態を操作できます。

```typescript
// Reactの外からも操作できる
useCounterStore.getState().count;         // 現在の値を取得
useCounterStore.setState({ count: 100 }); // 直接更新
useCounterStore.subscribe(() => {         // 変更を購読
  console.log('変わった:', useCounterStore.getState().count);
});
```

## Valtio・Jotai・XStateとの比較

同じ記事シリーズで紹介した [Valtio](/tomo_local/articles/react-mini-valtio)・[Jotai](/tomo_local/articles/react-mini-jotai)・[XState](/tomo_local/articles/react-mini-xstate) と比較してみましょう。

| | Valtio | Jotai | XState | Zustand |
|---|---|---|---|---|
| **データモデル** | ミュータブルなオブジェクト（Proxy） | イミュータブルなatom | 有限状態機械 | イミュータブルなStore |
| **状態の単位** | オブジェクト単位 | atom単位 | 状態機械単位 | Store単位 |
| **更新の書き方** | `state.count++` | `setCount(prev => prev + 1)` | `send('INCREMENT')` | `set({ count: count + 1 })` |
| **状態とアクション** | 別々 | 別々 | 別々 | 同じStoreにまとめて定義 |
| **コアAPI** | `Proxy` + `useSyncExternalStore` | `WeakMap` + `useReducer`/`useEffect` | `Set`（listeners）+ `useSyncExternalStore` | `Set`（listeners）+ `useSyncExternalStore` |
| **向いている場面** | フォームなど値の管理 | 細粒度の共有状態 | 複雑なフロー・状態遷移 | グローバルな状態管理全般 |

## まとめ

Zustandの仕組みを簡略化して実装することで、以下のことがわかりました。

- **`createStore` はReactを知らない純粋な状態コンテナ**であり、`getState` / `setState` / `subscribe` のシンプルなAPIを持つ。
- **`setState` はオブジェクトを自動でマージする**ため、部分的な更新をスプレッドなしで書ける。
- **`create` は `useSyncExternalStore` でStoreとReactを橋渡し**し、セレクタ関数を受け取ってスナップショットとして返す。
- **セレクタを使うと `===` 比較で再レンダリングを最小化**できる。プリミティブ値を返すセレクタが最も効果的。
- **状態とアクションを同じStoreに定義**できるため、Redux比でボイラープレートが大幅に少ない。

本家のZustandは、ここで紹介した機能に加えて、浅い比較セレクタ（`useShallow`）、ミドルウェア（`immer`, `persist`, `devtools`）による拡張機構、`subscribeWithSelector` ミドルウェアなどのより高度な機能が実装されています。

「シンプルなAPIでグローバルな状態をまとめて管理したい」という場面で、Zustandのアプローチは非常に強力な選択肢になります。

## GitHub

https://github.com/tomo-local/react-mini-zustand

## 参考

- [Zustand Documentation](https://zustand.docs.pmnd.rs/)
- [Zustand - GitHub](https://github.com/pmndrs/zustand)
- [React Docs: useSyncExternalStore](https://react.dev/reference/react/useSyncExternalStore)
