---
title: "TypeScriptのバリデーションライブラリ「Zod」を自作して仕組みを理解する"
emoji: "🔷"
type: "tech"
topics: ["typescript", "zod", "javascript", "frontend"]
published: false
---

## はじめに

Zodはランタイムでの値の検証と、TypeScriptの型推論を両立するバリデーションライブラリです。フォームの入力値やAPIレスポンスなど、「実行時に外から来る値」を安全に扱うために広く使われています。

この記事ではZodのコアコンセプトを理解するために、その簡易版を自作してみます。

:::message
**今回の簡易版の制約**
- `z.union()` / `z.enum()` / `z.literal()` は実装しません
- `.optional()` / `.nullable()` は実装しません
- `z.transform()` / `z.refine()` などの高度なメソッドは実装しません
- エラーメッセージのカスタマイズは実装しません
:::

## TypeScriptの型チェックとの比較

TypeScriptの型はコンパイル時にしか機能せず、実行時にはすべて消えてしまいます。

```typescript
// TypeScript はこれをコンパイルエラーにしない
const user: { name: string } = JSON.parse('{"name": 123}');
user.name.toUpperCase(); // 実行時エラー: name.toUpperCase is not a function
```

APIレスポンスやフォーム入力のように、実行時に外から来る値は `unknown` として扱うのが正確で、その値に型を付けるには実行時の検証が必要です。Zodはその検証と型付けを同時に行います。

```typescript
const UserSchema = z.object({ name: z.string() });

const user = UserSchema.parse(JSON.parse('{"name": 123}'));
// → ZodError: name: Expected string, received number
```

## Zodの仕組み（コンセプト）

Zodのスキーマは次の2つのメソッドを持つオブジェクトです。

| メソッド | 成功時 | 失敗時 |
|---------|--------|--------|
| `parse` | 検証済みの値を返す | `ZodError` を throw する |
| `safeParse` | `{ success: true, data }` を返す | `{ success: false, error }` を返す（throw しない） |

もうひとつ重要なのが `_type` フィールドです。これは **phantom type** と呼ばれるもので、実行時には値を持ちませんが、TypeScriptの型レベルでスキーマが表す型 `T` を保持します。`z.infer<T>` はここから型を取り出すだけのシンプルな型エイリアスです。

```typescript
type ZodType<T> = {
  readonly _type: T; // phantom type（実行時には存在しない）
  parse: (value: unknown) => T;
  safeParse: (value: unknown) => SafeParseResult<T>;
};

// z.infer は _type を取り出すだけ
type infer<T extends ZodType<unknown>> = T['_type'];
```

## 実装

### Step 1: スキーマの骨格を作る（`core.ts`）

まずスキーマの型定義と、スキーマオブジェクトを組み立てる `createSchema` 関数を実装します。

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

`createSchema` のポイントは、**検証ロジックを `parseFn` として渡すだけで、`parse` と `safeParse` が自動的に出来上がる**点です。`safeParse` は `parseFn` を `try/catch` で包んでいるだけなので、個々のスキーマに書く必要がありません。

### Step 2: プリミティブ型を実装する（`primitives.ts`）

`createSchema` を使って `z.string()` / `z.number()` / `z.boolean()` を実装します。各スキーマの実装は `typeof` チェックと `ZodError` を throw するだけです。

```typescript
import { createSchema, ZodError } from './core.js';

export const z = {
  // TypeScript の型チェックはコンパイル時にしか機能しないため、
  // 実行時に unknown な値を検証するにはこのような typeof チェックが必要
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

クラスの継承ではなく、**検証ロジックを関数として渡す**だけで新しいスキーマを追加できます。

## 実際に使ってみる

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

`safeParse` を使うと `try/catch` なしにエラーを扱えるため、フォームバリデーションのような「失敗が想定されるケース」に向いています。

## まとめ

- TypeScript の型はランタイムで消えるため、実行時の検証には `typeof` などのチェックが必要
- `createSchema(parseFn)` に検証ロジックを渡すだけでスキーマが作れる
- `parse` は失敗時に throw、`safeParse` は `{ success, data/error }` を返す
- `_type` フィールド（phantom type）で型情報をスキーマに埋め込む仕組みが `z.infer` の核心

## GitHub

https://github.com/tomo-local/typescript-mini-zod

## 参考

- [Zod Documentation](https://zod.dev/)
- [Zod - GitHub](https://github.com/colinhacks/zod)
