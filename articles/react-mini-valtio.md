---
title: "Reactの状態管理ライブラリ「Valtio」を自作して仕組みを理解する"
emoji: "🪄"
type: "tech"
topics: ["react", "valtio", "javascript", "proxy", "frontend"]
published: false
---

## はじめに

Reactの状態管理において、Valtioは非常にユニークな存在です。多くのライブラリがイミュータブル（不変）なデータの扱いを重視する中、ValtioはJavaScriptの `Proxy` を活用することで、**「ミュータブル（可変）な操作」を「リアクティブな更新」に変換**します。

この記事では、Valtioのコアコンセプトを理解するために、その簡易版を自作して、どのようにして状態の変更を検知し、Reactコンポーネントを再レンダリングさせているのかを探ります。

## 標準のState管理との比較

React標準の `useState` や `useContext` には、いくつかの設計上の制約や課題があります。

### 1. useStateのイミュータブル操作
`useState` では、状態を更新するために常に新しいオブジェクトを作成する必要があります。
```javascript
const [user, setUser] = useState({ name: 'taro', age: 20 });

// 直接変更しても再レンダリングされない
// user.name = 'jiro';

// 新しいオブジェクトを作る必要がある
setUser({ ...user, name: 'jiro' });
```
深くネストされたオブジェクトの場合、スプレッド演算子を多用することになり、コードが複雑になりがちです。

### 2. useContextの再レンダリング問題
`Context` を使うと、コンテキスト内の**一部の値**が更新されただけで、そのコンテキストを購読している**すべてのコンポーネント**が再レンダリングされてしまいます。

Valtioはこれらの問題を、プロキシベースのアプローチで解決します。

## Valtioの仕組み（コンセプト）

Valtioの核となるのは、JavaScriptの `Proxy` APIです。
`Proxy` を使うと、オブジェクトに対する読み取り（get）や書き込み（set）の操作をトラップ（横取り）できます。

1. **変更検知**: `Proxy` の `set` トラップを使って、プロパティが変更された瞬間に登録されたリスナー（購読者）へ通知します。
2. **購読 (Subscribe)**: 状態が変化した時に実行したい処理を登録します。
3. **Reactへの同期**: 変更通知を受け取った際に、Reactコンポーネントを再レンダリングさせます。

## 簡易版Valtioの実装

それでは、TypeScriptを使って `mini-valtio` を実装してみましょう。

:::message
**今回の簡易版の制約**
- ネストされたオブジェクト（例: `state.user.name = '...'`）の変更は検知できません。本家Valtioは再帰的にProxyを適用することでこれに対応しています。
- `useSnapshot` は `useSyncExternalStore` を使用しているため、SSR（サーバーサイドレンダリング）環境では第3引数 `getServerSnapshot` の実装が別途必要です。
:::

### Step 1: `proxy` 関数の実装

まずは、オブジェクトを `Proxy` で包み、変更を検知する `proxy` 関数を作ります。

> 📎 本家Valtioの実装: [proxy - src/vanilla.ts](https://github.com/pmndrs/valtio/blob/main/src/vanilla.ts)

```typescript
type Listener = () => void;

export function proxy<T extends object>(initialObject: T): T {
  const listeners = new Set<Listener>();

  return new Proxy(initialObject, {
    set(target, prop, value) {
      if (Reflect.get(target, prop) === value) return true;

      // 値を更新
      const result = Reflect.set(target, prop, value);

      // 変更を通知
      listeners.forEach((l) => l());

      return result;
    },
    get(target, prop) {
      // 内部的にリスナーを操作するための特殊なプロパティを隠しておく
      if (prop === '_listeners') return listeners;
      return Reflect.get(target, prop);
    },
  });
}
```

:::details _listeners という名前の衝突リスクについて
今回は簡易実装のため `_listeners` という文字列キーでリスナーを取り出していますが、ユーザーが同名のプロパティを持つオブジェクトを渡すと衝突します。本家ValtioではWeakMapや `Symbol` を使って内部状態を外部から隠蔽し、この問題を回避しています。
:::

### Step 2: `subscribe` 関数の実装

次に、作成したプロキシオブジェクトの変更を購読する関数を作ります。

> 📎 本家Valtioの実装: [subscribe - src/vanilla.ts](https://github.com/pmndrs/valtio/blob/main/src/vanilla.ts)

```typescript
export function subscribe(proxyObject: any, callback: Listener) {
  const listeners = proxyObject._listeners as Set<Listener>;
  listeners.add(callback);

  // アンサブスクライブ関数を返す
  return () => listeners.delete(callback);
}
```

### Step 3: `useSnapshot` Hookの実装

最後に、Reactコンポーネントからこの状態を使うためのHookを実装します。ここでは、React 18で導入された `useSyncExternalStore` を使います。

> 📎 本家Valtioの実装: [useSnapshot - src/react.ts](https://github.com/pmndrs/valtio/blob/main/src/react.ts)

`useSyncExternalStore` の `getSnapshot` は、値が変わっていなければ**同一の参照**を返す必要があります。毎回新しいオブジェクトを返すと無限に再レンダリングが起きてしまうため、`WeakMap` で前回のスナップショットをキャッシュし、各プロパティを浅く比較して変化がなければキャッシュをそのまま返すようにしています。

```typescript
import { useSyncExternalStore } from 'react';

const snapshotCache = new WeakMap<object, object>();

export function useSnapshot<T extends object>(proxyObject: T): T {
  // 外部ストア（Proxy）の現在のスナップショットを取得し、変更時に同期する
  return useSyncExternalStore(
    (callback) => subscribe(proxyObject, callback),
    () => {
      // 前回のスナップショットをキャッシュから取得
      const prev = snapshotCache.get(proxyObject) as T | undefined;
      const next = { ...proxyObject };
      if (prev) {
        const keys = Object.keys(next) as (keyof T)[];
        if (!keys.some((k) => next[k] !== prev[k])) return prev;
      }
      snapshotCache.set(proxyObject, next);
      return next;
    }
  );
}
```

## 実際に使ってみる

実装した `mini-valtio` を使って、カウンターアプリを作ってみましょう。

```tsx
import React from 'react';
import { proxy, useSnapshot } from './mini-valtio';

// 1. 状態の作成（ミュータブルなオブジェクト）
const state = proxy({ count: 0, text: 'Hello' });

const Counter = () => {
  // 2. スナップショットを取得
  const snap = useSnapshot(state);

  return (
    <div>
      <p>Count: {snap.count}</p>
      {/* 3. 直接プロキシオブジェクトを操作して更新！ */}
      <button onClick={() => state.count++}>Increment</button>
    </div>
  );
};

const TextInput = () => {
  const snap = useSnapshot(state);
  return (
    <input
      value={snap.text}
      onChange={(e) => (state.text = e.target.value)}
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

## まとめ

Valtioの仕組みを簡略化して実装することで、以下のことがわかりました。

- **Proxy API** により、開発者は使い慣れたミュータブルな書き方で状態を操作できる。
- **Observerパターン**（subscribe）により、変更があった時だけ通知を送る。
- **useSyncExternalStore** により、Reactの外部にある状態を安全に、かつ効率的にコンポーネントへ同期できる。

本家のValtioは、ここで紹介した機能に加えて、ネストされたオブジェクトの再帰的なプロキシ化や、レンダリングに必要なプロパティだけを追跡して再レンダリングを最小限に抑える「Render Optimization」などの高度な最適化が行われています。

「複雑な状態をシンプルに扱いたい」という場面で、Valtioのようなプロキシベースのアプローチは非常に強力な選択肢になります。

## GitHub

https://github.com/tomo-local/react-mini-valtio

## 参考
- [Valtio Documentation](https://valtio.pmnd.rs/)
- [MDN: Proxy](https://developer.mozilla.org/ja/docs/Web/JavaScript/Reference/Global_Objects/Proxy)
- [React Docs: useSyncExternalStore](https://react.dev/reference/react/useSyncExternalStore)
