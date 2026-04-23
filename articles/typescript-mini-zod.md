---
title: "TypeScriptのバリデーションライブラリ「Zod」を自作して仕組みを理解する"
emoji: "🔷"
type: "tech"
topics: ["typescript", "zod", "javascript", "frontend"]
published: true
---

## はじめに

今回はZodのコアコンセプトを理解するために、簡易版をスクラッチで自作していきたいと思います。まず動かしてみて、少しずつ仕組みを理解していくスタイルで進めていきます。

ZodはTypeScriptと組み合わせて、プログラムが実際に動いているときの値の検証を行うライブラリです。フォームの入力値やAPIのレスポンスなど、外から来る値を安全に扱うために広く使われています。

:::message
**今回の簡易版の制約**
- `z.union()` / `z.enum()` / `z.literal()` は実装しません
- `.optional()` / `.nullable()` は実装しません
- `z.transform()` / `z.refine()` などの高度なメソッドは実装しません
- エラーメッセージのカスタマイズは実装しません
:::

## TypeScriptの型チェックとの違い

TypeScriptの型はコードを書くときにしか機能せず、実際にプログラムが動くときには消えてしまいます。

```typescript
// TypeScript はこれをエラーにしない
const user: { name: string } = JSON.parse('{"name": 123}');
user.name.toUpperCase(); // 動かすと壊れる: name.toUpperCase is not a function
```

APIのレスポンスやフォームの入力のように、動かしているときに外から来る値は、どんな値が入ってくるかわかりません。Zodはそういった値を実際に動かしながら検証して、TypeScriptの型としても使えるようにしてくれます。

```typescript
const UserSchema = z.object({ name: z.string() });

const user = UserSchema.parse(JSON.parse('{"name": 123}'));
// → ZodError: name: Expected string, received number
```

## Zodの仕組み（コンセプト）

実装に入る前に、Zodのスキーマがどんな構造をしているか簡単に整理しておきたいと思います。スキーマは次の2つのメソッドを持つオブジェクトです。

| メソッド | 成功時 | 失敗時 |
|---------|--------|--------|
| `parse` | 検証済みの値を返す | `ZodError` を throw する |
| `safeParse` | `{ success: true, data }` を返す | `{ success: false, error }` を返す（throw しない） |

もうひとつ重要なのが `_type` フィールドです。実際に動かすときには値を持ちませんが、TypeScriptがコードを書くときにスキーマの型 `T` を把握するために使われます。`z.infer<T>` はここから型を取り出すだけのシンプルな仕組みです。

```typescript
type ZodType<T> = {
  readonly _type: T; // 実行時には存在しない、型のための情報
  parse: (value: unknown) => T;
  safeParse: (value: unknown) => SafeParseResult<T>;
};

// z.infer は _type を取り出すだけ
type infer<T extends ZodType<unknown>> = T['_type'];
```

## 実装

### Step 1: スキーマの骨格を作る（`core.ts`）

まずスキーマの型定義と、スキーマオブジェクトを組み立てる `createSchema` 関数を実装していきたいと思います。

では、コードを見ていきましょう！

```typescript
export class ZodError extends Error {
  constructor(public message: string) {
    super(message);
    this.name = 'ZodError';
  }
}

export type SafeParseResult<T> =
  | { success: true; data: T }
  | { success: false; error: ZodError };

export type ZodType<T> = {
  readonly _type: T;
  parse: (value: unknown) => T;
  safeParse: (value: unknown) => SafeParseResult<T>;
};

// 検証ロジック（parseFn）だけ渡すと、parse/safeParse を持つスキーマオブジェクトができる
export function createSchema<T>(parseFn: (value: unknown) => T): ZodType<T> {
  return {
    parse: parseFn,
    safeParse: (value) => {
      try {
        return { success: true, data: parseFn(value) };
      } catch (e) {
        if (e instanceof ZodError) return { success: false, error: e };
        throw e;
      }
    },
  } as ZodType<T>;
}
```

`createSchema` のポイントは、検証ロジックを `parseFn` として渡すだけで `parse` と `safeParse` が自動的に出来上がる点です。`safeParse` は `parseFn` を `try/catch` で包んでいるだけなので、個々のスキーマに書く必要がありません！

### Step 2: プリミティブ型を実装する（`primitives.ts`）

`createSchema` を使って `z.string()` / `z.number()` / `z.boolean()` を実装していきたいと思います。各スキーマの実装は `typeof` チェックと `ZodError` を throw するだけなのでシンプルです。

では、コードを見ていきましょう！

```typescript
import { createSchema, ZodError } from './core.js';

export const z = {
  // TypeScript の型チェックはコードを書くときにしか機能しないため、
  // 実際に動かすときに値を検証するにはこのような typeof チェックが必要
  string: () =>
    createSchema<string>((value) => {
      if (typeof value !== 'string') {
        throw new ZodError(`Expected string, received ${typeof value}`);
      }
      return value;
    }),

  number: () =>
    createSchema<number>((value) => {
      if (typeof value !== 'number') {
        throw new ZodError(`Expected number, received ${typeof value}`);
      }
      return value;
    }),

  boolean: () =>
    createSchema<boolean>((value) => {
      if (typeof value !== 'boolean') {
        throw new ZodError(`Expected boolean, received ${typeof value}`);
      }
      return value;
    }),
};
```

クラスの継承ではなく、検証ロジックを関数として渡すだけで新しいスキーマを追加できます。拡張しやすい設計だと思います！

## 実際に使ってみる

では実際に動かしてみましょう！

```typescript
// parse: 成功
const name = z.string().parse('Alice');
// → "Alice"

// parse: 失敗（ZodError を throw）
z.string().parse(123);
// → ZodError: Expected string, received number

// safeParse: 成功
const result1 = z.string().safeParse('hello');
if (result1.success) {
  console.log(result1.data); // "hello"（string 型として使える）
}

// safeParse: 失敗（throw しない）
const result2 = z.number().safeParse('not a number');
if (!result2.success) {
  console.log(result2.error.message); // "Expected number, received string"
}
```

`safeParse` を使うと `try/catch` なしにエラーを扱えます。フォームのバリデーションのような「失敗が想定されるケース」に向いていると思います。

## まとめ

- TypeScriptの型はコードを書くときにしか機能しないため、実際に動かすときの検証には `typeof` などのチェックが必要
- `createSchema(parseFn)` に検証ロジックを渡すだけでスキーマが作れる
- `parse` は失敗時に throw、`safeParse` は `{ success, data/error }` を返す
- `_type` フィールドでTypeScriptが型を把握できる仕組みが `z.infer` の核心

## GitHub

https://github.com/tomo-local/typescript-mini-zod

## 参考

- [Zod Documentation](https://zod.dev/)
- [Zod - GitHub](https://github.com/colinhacks/zod)
