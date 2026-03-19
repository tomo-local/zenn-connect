---
title: "Reactの状態管理ライブラリ「Jotai」を自作して仕組みを理解する"
emoji: "⚛️"
type: "tech"
topics: ["react", "jotai", "javascript", "typescript", "frontend", "state"]
published: true
---

## はじめに

Reactの状態管理において、Jotaiは「アトミック（原子的）」なアプローチで注目されているライブラリです。ReduxやZustandがアプリ全体の状態をひとつのストアで管理するのに対し、Jotaiは `atom` という小さな単位に状態を分割して管理します。

この記事では、Jotaiのコアコンセプトを理解するために、その簡易版を自作して、どのようにしてatomが状態を保持し、Reactコンポーネントを再レンダリングさせているのかを探ります。

## 標準のState管理との比較

React標準の `useState` や `useContext` には、いくつかの設計上の制約や課題があります。

### 1. useStateのスコープ問題

`useState` はコンポーネントローカルな状態管理には最適ですが、複数のコンポーネント間で状態を共有するためには `useContext` と組み合わせる必要があります。

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

Jotaiはこれらの問題を、atomという小さな単位に状態を分割することで解決します。

## Jotaiの仕組み（コンセプト）

Jotaiのポイントは、状態を **「atom（アトム）」** という小さな単位に分割して管理することです。

1. **atom**: 状態の定義だけを持つ軽量なオブジェクト。実際の値は保持しない。
2. **Store**: atomの実際の値とリスナーを管理する。`get` / `set` / `sub` のAPIを持つ。
3. **useAtom**: `useContext` でStoreを取得し、`useReducer` と `useEffect` でReactと同期するhook。

`atom` 自体はただの「設定オブジェクト」で、実際の値はStoreが管理します。
コンポーネントは自分が使う `atom` だけを購読するため、無関係な状態変化では再レンダリングされません。

## 簡易版Jotaiの実装

それでは、TypeScriptを使って `mini-jotai` を実装してみましょう。

:::message
**今回の簡易版の制約**
- 派生atom（`atom((get) => get(otherAtom) * 2)` のような計算されるatom）は実装しません。本家Jotaiはatomのread関数で他のatomの値を参照できます。
- `Provider` コンポーネントは実装を省略し、グローバルなデフォルトStoreのみを使用します。
:::

### Step 1: `atom` 関数の実装

まずは、状態の「定義」となる `atom` 関数を作ります。`atom` は初期値を受け取り、軽量な設定オブジェクトを返すだけです。

> 📎 本家Jotaiの実装: [atom - src/vanilla/atom.ts](https://github.com/pmndrs/jotai/blob/3ee4fcb562ec8e471c46482cad6dd21242ed27d3/src/vanilla/atom.ts#L101)

```typescript
export type Atom<T> = {
  init: T;
};

export function atom<T>(initialValue: T): Atom<T> {
  return { init: initialValue };
}
```

`atom` の本体はこれだけです。**実際の値は持たない** ことがポイントです。

### Step 2: Storeの実装

次に、atomの値とリスナーを管理するStoreを作ります。本家Jotaiに倣い、`get` / `set` / `sub` の3つのAPIを持つオブジェクトとして実装します。内部では `WeakMap` を使い、atomが不要になれば自動的にガベージコレクションされます。

> 📎 本家Jotaiの実装: [createStore - src/vanilla/store.ts](https://github.com/pmndrs/jotai/blob/3ee4fcb562ec8e471c46482cad6dd21242ed27d3/src/vanilla/store.ts#L14)

```typescript
import { Atom } from './atom';

type Listener = () => void;

type AtomState<T> = {
  value: T;
  listeners: Set<Listener>;
};

export function createStore() {
  const atomStateMap = new WeakMap<object, AtomState<any>>();

  function getAtomState<T>(atom: Atom<T>): AtomState<T> {
    if (!atomStateMap.has(atom)) {
      atomStateMap.set(atom, { value: atom.init, listeners: new Set() });
    }
    return atomStateMap.get(atom)!;
  }

  return {
    // atomの現在値を取得
    get<T>(atom: Atom<T>): T {
      return getAtomState(atom).value;
    },
    // atomの値を更新し、リスナーへ通知
    set<T>(atom: Atom<T>, value: T): void {
      const state = getAtomState(atom);
      if (Object.is(state.value, value)) return;
      state.value = value;
      state.listeners.forEach((l) => l());
    },
    // atomの変更を購読し、アンサブスクライブ関数を返す
    sub<T>(atom: Atom<T>, listener: Listener): () => void {
      const state = getAtomState(atom);
      state.listeners.add(listener);
      return () => state.listeners.delete(listener);
    },
  };
}

export type Store = ReturnType<typeof createStore>;

// グローバルなデフォルトStore
let defaultStore: Store | undefined;
export function getDefaultStore(): Store {
  if (!defaultStore) defaultStore = createStore();
  return defaultStore;
}
```

:::details WeakMapを使う理由
通常の `Map` でatomを管理すると、atomオブジェクトが参照され続けるためガベージコレクションされません。`WeakMap` を使えば、atomが他の場所で参照されなくなった際に自動でメモリが解放されます。
:::

### Step 3: `useAtom` Hookの実装

最後に、ReactコンポーネントからatomをRead/WriteするためのHookを実装します。

本家Jotaiは `useSyncExternalStore` ではなく、**`useReducer`** と **`useEffect`** を組み合わせてStoreとReactを同期しています。また、Storeへのアクセスには **`useContext`** を使用しています。

`useSyncExternalStore` を使わない理由は、APIの名前にある "Sync（同期）" にあります。このAPIはReactに対して「常に同期的に更新せよ」と強制するため、React 18の**Concurrent機能（Time SlicingやTransition）を無効化**してしまいます。具体的には `useTransition` と組み合わせた際に、ペンディング中の状態が正しく表示されずSuspenseフォールバックが出てしまうといった問題が起きます。

一方 `useReducer` + `useEffect` の組み合わせであれば、Reactが更新を自由にスケジュールできるため、`useTransition` や非同期atomとの相性が良くなります。ただし、Concurrent Renderingの過程でコンポーネント間に一瞬の状態の不一致（**tearing**）が生じる可能性は受け入れています。

> 📎 参考: [Why useSyncExternalStore Is Not Used in Jotai - Daishi Kato's Blog](https://blog.axlight.com/posts/why-use-sync-external-store-is-not-used-in-jotai/)

> 📎 本家Jotaiの実装: [useAtom - src/react/useAtom.ts](https://github.com/pmndrs/jotai/blob/3ee4fcb562ec8e471c46482cad6dd21242ed27d3/src/react/useAtom.ts#L47)

```typescript
import { createContext, useCallback, useContext, useEffect, useReducer } from 'react';
import { Atom } from './atom';
import { Store, getDefaultStore } from './store';

// useContextでStoreを共有するためのContext
const StoreContext = createContext<Store | undefined>(undefined);

function useStore(): Store {
  return useContext(StoreContext) ?? getDefaultStore();
}

export function useAtom<T>(
  atom: Atom<T>,
): [T, (value: T | ((prev: T) => T)) => void] {
  const store = useStore();

  // useReducerでatomの値を管理し、rerenderで再レンダリングをトリガーする
  const [[value, prevStore, prevAtom], rerender] = useReducer(
    (prev: readonly [T, Store, typeof atom]) => {
      const nextValue = store.get(atom);
      // 値・store・atomが変わっていなければ同じ参照を返して再レンダリングを防ぐ
      if (Object.is(prev[0], nextValue) && prev[1] === store && prev[2] === atom) {
        return prev;
      }
      return [nextValue, store, atom] as const;
    },
    undefined,
    () => [store.get(atom), store, atom] as const,
  );

  // storeやatomが変わった場合は即座に同期
  let currentValue = value;
  if (prevStore !== store || prevAtom !== atom) {
    rerender();
    currentValue = store.get(atom);
  }

  // useEffectでStoreの変更を購読し、変更があればrerenderを呼ぶ
  useEffect(() => {
    const unsub = store.sub(atom, rerender);
    rerender(); // マウント後に最新値を取得
    return unsub;
  }, [store, atom]);

  // 値の書き込み: 関数型の更新にも対応
  const setValue = useCallback(
    (newValue: T | ((prev: T) => T)) => {
      const next =
        typeof newValue === 'function'
          ? (newValue as (prev: T) => T)(store.get(atom))
          : newValue;
      store.set(atom, next);
    },
    [store, atom],
  );

  return [currentValue, setValue];
}
```

`useEffect` で `store.sub(atom, rerender)` を呼ぶことで、atomの変更があるたびに `rerender`（= `useReducer` のdispatch）が実行され、コンポーネントが再レンダリングされます。`useReducer` のリデューサー内で値が変化していなければ同じ参照を返すため、不要な再レンダリングを防いでいます。

## 実際に使ってみる

実装した `mini-jotai` を使って、カウンターアプリを作ってみましょう。

```tsx
import React from 'react';
import { atom } from './mini-jotai/atom';
import { useAtom } from './mini-jotai/useAtom';

// 1. atomの定義（モジュールのトップレベルに置く）
const countAtom = atom(0);
const textAtom = atom('Hello');

const Counter = () => {
  // 2. countAtomだけを購読 → textが変わっても再レンダリングされない
  const [count, setCount] = useAtom(countAtom);

  return (
    <div>
      <p>Count: {count}</p>
      {/* 3. setterは useState と同じインターフェース */}
      <button onClick={() => setCount((prev) => prev + 1)}>Increment</button>
    </div>
  );
};

const TextInput = () => {
  // textAtomだけを購読 → countが変わっても再レンダリングされない
  const [text, setText] = useAtom(textAtom);

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

`Counter` は `countAtom` のみ、`TextInput` は `textAtom` のみを購読しています。そのため、`countAtom` が変化しても `TextInput` は再レンダリングされず、逆も同様です。

## ValtioとJotaiの比較

同じ記事シリーズで紹介した [Valtio](/react-mini-valtio) と比較してみましょう。

| | Valtio | Jotai |
|---|---|---|
| **データモデル** | ミュータブルなオブジェクト（Proxy） | イミュータブルなatom |
| **更新の書き方** | `state.count++`（直接変更） | `setCount(prev => prev + 1)` |
| **状態の単位** | オブジェクト単位 | atom単位 |
| **再レンダリング最適化** | 使用プロパティを追跡 | 購読atomのみ |
| **コアAPI** | `Proxy` + `useSyncExternalStore` | `WeakMap` + `useReducer` / `useEffect` |

## まとめ

Jotaiの仕組みを簡略化して実装することで、以下のことがわかりました。

- **atomはただの設定オブジェクト**であり、実際の値は `WeakMap` ベースのStoreが管理している。
- **Storeは `get` / `set` / `sub` のシンプルなAPI**を持ち、atomの値管理と購読を担う。
- **`useContext`** でコンポーネントツリーにStoreを共有し、**`useEffect`** で変更を購読する。
- **`useReducer`** のdispatchをリスナーとして使うことで、atomの変更をReactの再レンダリングに橋渡しする。
- コンポーネントは**自分が使うatomだけを購読**するため、無関係な状態変化で再レンダリングされない。

本家のJotaiは、ここで紹介した機能に加えて、派生atom（他のatomの値を参照して計算されるatom）、`Provider` による複数Storeの分離、非同期atom（Promiseを返すatom）などの高度な機能が実装されています。

「状態を細かい単位に分割して、必要なコンポーネントだけが再レンダリングされるようにしたい」という場面で、Jotaiのアトミックなアプローチは非常に強力な選択肢になります。

## 参考

- [Jotai Documentation](https://jotai.org/)
- [Jotai - GitHub](https://github.com/pmndrs/jotai)
- [MDN: WeakMap](https://developer.mozilla.org/ja/docs/Web/JavaScript/Reference/Global_Objects/WeakMap)
- [React Docs: useReducer](https://react.dev/reference/react/useReducer)
- [React Docs: useEffect](https://react.dev/reference/react/useEffect)
