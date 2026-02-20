---
title: "【Go】標準パッケージだけで永続化機能付きKVSを自作する"
emoji: "🗄️"
type: "tech"
topics: ["go", "golang", "kvs", "標準パッケージ"]
published: false
---

## はじめに

「Key-Value Store（KVS）を自分で実装する」と聞くと、大げさに感じるかもしれません。RedisやBoltDBなど、優れたソリューションがすでに存在するからです。

しかし、**標準パッケージだけで最小限のKVSを自作する**ことには、大きな学習的価値があります。

- Goの並行処理における排他制御の実践
- ファイルI/Oとバイナリエンコーディングの理解
- Graceful Shutdownパターンの習得

本記事では、約100行程度のコードで「**スレッドセーフ**」かつ「**永続化可能**」なKVSを実装します。明日からあなたのプロジェクトでも応用できる知識を、一緒に身につけていきましょう。

---

## 設計方針

### なぜ `sync.RWMutex` を選ぶのか

並行アクセスを制御するために、Goでは `sync.Mutex` と `sync.RWMutex` の2つの選択肢があります。

| 特性 | `sync.Mutex` | `sync.RWMutex` |
|------|-------------|----------------|
| 読み取りロック | 排他的 | **共有可能** |
| 書き込みロック | 排他的 | 排他的 |
| 読み取り多数の場合 | ボトルネック | **高パフォーマンス** |

KVSは一般的に「**読み取りが多く、書き込みは比較的少ない**」という特性を持ちます。`sync.RWMutex` を使用することで、複数のgoroutineが同時に読み取りを行えるため、スループットが向上します。

:::message
**ポイント**: `RLock()` / `RUnlock()` で読み取りロック、`Lock()` / `Unlock()` で書き込みロックを取得します。読み取り操作には必ず読み取りロックを使いましょう。
:::

### 構造体の設計

```go
type KVS struct {
    data     map[string]string
    mu       sync.RWMutex
    filePath string
}
```

- **`data`**: 実際のキーバリューデータを格納
- **`mu`**: 並行アクセスを制御するミューテックス
- **`filePath`**: 永続化先のファイルパス

---

## 実装

### 完全なソースコード

まずは全体像を把握するため、完全なソースコードを示します。

```go
package main

import (
    "encoding/gob"
    "fmt"
    "os"
    "os/signal"
    "sync"
    "syscall"
)

// KVS はスレッドセーフなKey-Value Storeです
type KVS struct {
    data     map[string]string
    mu       sync.RWMutex
    filePath string
}

// NewKVS は新しいKVSインスタンスを作成します
func NewKVS(filePath string) *KVS {
    return &KVS{
        data:     make(map[string]string),
        filePath: filePath,
    }
}

// Get は指定されたキーの値を取得します
func (k *KVS) Get(key string) (string, bool) {
    k.mu.RLock()
    defer k.mu.RUnlock()

    value, exists := k.data[key]
    return value, exists
}

// Set は指定されたキーに値を設定します
func (k *KVS) Set(key, value string) {
    k.mu.Lock()
    defer k.mu.Unlock()

    k.data[key] = value
}

// Delete は指定されたキーを削除します
func (k *KVS) Delete(key string) {
    k.mu.Lock()
    defer k.mu.Unlock()

    delete(k.data, key)
}

// Save はデータをファイルに永続化します
func (k *KVS) Save() error {
    k.mu.RLock()
    defer k.mu.RUnlock()

    file, err := os.Create(k.filePath)
    if err != nil {
        return fmt.Errorf("failed to create file: %w", err)
    }
    defer file.Close()

    encoder := gob.NewEncoder(file)
    if err := encoder.Encode(k.data); err != nil {
        return fmt.Errorf("failed to encode data: %w", err)
    }

    return nil
}

// Load はファイルからデータを読み込みます
func (k *KVS) Load() error {
    k.mu.Lock()
    defer k.mu.Unlock()

    file, err := os.Open(k.filePath)
    if err != nil {
        if os.IsNotExist(err) {
            // ファイルが存在しない場合は新規作成として扱う
            return nil
        }
        return fmt.Errorf("failed to open file: %w", err)
    }
    defer file.Close()

    decoder := gob.NewDecoder(file)
    if err := decoder.Decode(&k.data); err != nil {
        return fmt.Errorf("failed to decode data: %w", err)
    }

    return nil
}

func main() {
    kvs := NewKVS("kvs_data.gob")

    // 既存データの読み込み
    if err := kvs.Load(); err != nil {
        fmt.Printf("Warning: Failed to load data: %v\n", err)
    }

    // Graceful Shutdown の設定
    sigChan := make(chan os.Signal, 1)
    signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

    // 終了シグナルを待機するgoroutine
    go func() {
        <-sigChan
        fmt.Println("\nShutting down...")
        if err := kvs.Save(); err != nil {
            fmt.Printf("Error saving data: %v\n", err)
            os.Exit(1)
        }
        fmt.Println("Data saved successfully!")
        os.Exit(0)
    }()

    // サンプル操作
    kvs.Set("name", "Gopher")
    kvs.Set("language", "Go")
    kvs.Set("version", "1.21")

    // 値の取得
    if name, exists := kvs.Get("name"); exists {
        fmt.Printf("name: %s\n", name)
    }

    // 全データの表示
    fmt.Println("--- Stored Data ---")
    for _, key := range []string{"name", "language", "version"} {
        if value, exists := kvs.Get(key); exists {
            fmt.Printf("%s: %s\n", key, value)
        }
    }

    // 手動で保存してみる
    if err := kvs.Save(); err != nil {
        fmt.Printf("Error: %v\n", err)
    } else {
        fmt.Println("Data saved to file!")
    }

    // 終了シグナルを待機（Ctrl+C で終了）
    fmt.Println("\nPress Ctrl+C to exit...")
    select {}
}
```

---

## 各部分の詳細解説

### 基本メソッド: Get / Set / Delete

#### Get メソッド

```go
func (k *KVS) Get(key string) (string, bool) {
    k.mu.RLock()         // 読み取りロックを取得
    defer k.mu.RUnlock() // 関数終了時にロック解放

    value, exists := k.data[key]
    return value, exists
}
```

**`RLock()`** を使用することで、複数のgoroutineが同時に `Get()` を呼び出せます。これがパフォーマンス向上のカギです。

:::details なぜ2つの戻り値を返すのか
Goの慣習として、mapからの値取得では「値が存在するかどうか」を`bool`で返します。これにより、**空文字列が格納されている場合**と**キーが存在しない場合**を区別できます。
:::

#### Set メソッド

```go
func (k *KVS) Set(key, value string) {
    k.mu.Lock()         // 書き込みロックを取得
    defer k.mu.Unlock() // 関数終了時にロック解放

    k.data[key] = value
}
```

書き込み操作では **`Lock()`** を使用し、排他的にアクセスします。この間、他のgoroutineは読み取りも書き込みもできません。

#### Delete メソッド

```go
func (k *KVS) Delete(key string) {
    k.mu.Lock()
    defer k.mu.Unlock()

    delete(k.data, key)
}
```

削除もデータを変更する操作なので、書き込みロックを取得します。

---

### 永続化機能: encoding/gob の活用

#### なぜ `encoding/gob` を選ぶのか

Goには複数のシリアライズ形式があります。

| 形式 | パッケージ | 特徴 |
|------|----------|------|
| JSON | `encoding/json` | 人間が読める、言語間互換性 |
| **Gob** | `encoding/gob` | **Go専用、高速、コンパクト** |
| XML | `encoding/xml` | 冗長、レガシーシステム向け |

今回は **Go内部での永続化** が目的のため、以下の理由で `gob` を選択しました。

1. **パフォーマンス**: JSONより高速にエンコード/デコードできる
2. **サイズ効率**: バイナリ形式のため、ファイルサイズが小さい
3. **型安全**: Go の型情報を保持できる

:::message alert
**注意**: gobファイルは人間が直接読めません。デバッグ用途や他言語との連携が必要な場合は、JSONを検討してください。
:::

#### Save メソッド

```go
func (k *KVS) Save() error {
    k.mu.RLock()         // 読み取りロックで十分
    defer k.mu.RUnlock()

    // ファイルを作成（既存ファイルは上書き）
    file, err := os.Create(k.filePath)
    if err != nil {
        return fmt.Errorf("failed to create file: %w", err)
    }
    defer file.Close()

    // gobエンコーダーでデータを書き込み
    encoder := gob.NewEncoder(file)
    if err := encoder.Encode(k.data); err != nil {
        return fmt.Errorf("failed to encode data: %w", err)
    }

    return nil
}
```

**ポイント**: `Save()` ではデータを読み取るだけなので、**読み取りロック**で十分です。これにより、保存中も `Get()` 操作は実行可能です。

#### Load メソッド

```go
func (k *KVS) Load() error {
    k.mu.Lock()         // 書き込みロック（dataを変更するため）
    defer k.mu.Unlock()

    file, err := os.Open(k.filePath)
    if err != nil {
        if os.IsNotExist(err) {
            return nil  // ファイルがなければ新規扱い
        }
        return fmt.Errorf("failed to open file: %w", err)
    }
    defer file.Close()

    decoder := gob.NewDecoder(file)
    if err := decoder.Decode(&k.data); err != nil {
        return fmt.Errorf("failed to decode data: %w", err)
    }

    return nil
}
```

**ポイント**: `Load()` は `k.data` を上書きするため、**書き込みロック**を取得します。

---

### Graceful Shutdown: データを安全に保存

プログラムが `Ctrl+C` などで終了される際、保存されていないデータが失われる可能性があります。`os/signal` パッケージを使用して、終了シグナルをキャッチし、安全にデータを保存しましょう。

```go
func main() {
    kvs := NewKVS("kvs_data.gob")

    // シグナルを受け取るチャネル
    sigChan := make(chan os.Signal, 1)

    // SIGINT (Ctrl+C) と SIGTERM をキャッチ
    signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

    // 別goroutineでシグナルを待機
    go func() {
        <-sigChan  // シグナルを受信するまでブロック
        fmt.Println("\nShutting down...")

        if err := kvs.Save(); err != nil {
            fmt.Printf("Error saving data: %v\n", err)
            os.Exit(1)
        }

        fmt.Println("Data saved successfully!")
        os.Exit(0)
    }()

    // メイン処理...
}
```

:::message
**ベストプラクティス**: 本番環境では、シグナルハンドラ内で `context.Context` を使用してタイムアウトを設定することで、保存処理が無限に待機することを防げます。
:::

---

## 動作確認

### ビルドと実行

```bash
$ go build -o kvs main.go
$ ./kvs
```

### 実行結果

```
name: Gopher
--- Stored Data ---
name: Gopher
language: Go
version: 1.21
Data saved to file!

Press Ctrl+C to exit...
^C
Shutting down...
Data saved successfully!
```

### データファイルの確認

```bash
$ ls -la kvs_data.gob
-rw-r--r--  1 user  staff  67 Feb 21 10:00 kvs_data.gob

$ file kvs_data.gob
kvs_data.gob: data
```

バイナリファイルとして保存されていることが確認できます。

---

## 発展的なトピック

### 1. TTL (Time To Live) の実装

```go
type KVS struct {
    data     map[string]entry
    mu       sync.RWMutex
    filePath string
}

type entry struct {
    Value     string
    ExpiresAt time.Time
}
```

### 2. 定期的な自動保存

```go
go func() {
    ticker := time.NewTicker(5 * time.Minute)
    for range ticker.C {
        kvs.Save()
    }
}()
```

### 3. トランザクション的な操作

複数のキーを原子的に更新する `SetMulti()` メソッドの追加も検討できます。

---

## まとめ

本記事では、Goの標準パッケージだけで「永続化機能付きKVS」を実装しました。

### 学んだこと

| トピック | 内容 |
|---------|------|
| **排他制御** | `sync.RWMutex` で読み取り / 書き込みロックを使い分ける |
| **永続化** | `encoding/gob` でバイナリシリアライズ |
| **Graceful Shutdown** | `os/signal` でプロセス終了時に安全に保存 |

### 車輪の再発明から得られる知見

既存のライブラリを使えば一瞬で実現できることを、あえて自分で実装することで、**内部の仕組みを深く理解**できます。この理解があると、ライブラリ選定時の判断力が上がり、トラブルシューティングも容易になります。

ぜひ、今回のコードをベースに独自の機能を追加して、Goの並行処理パターンをさらに深く探求してみてください。

---

最後までお読みいただき、ありがとうございました。質問やフィードバックがあれば、コメント欄でお気軽にどうぞ！
