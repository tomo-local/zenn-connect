---
title: "【Go】標準パッケージだけで永続化機能付きKVSを自作する"
emoji: "🗄️"
type: "tech"
topics: ["go", "golang", "kvs", "標準パッケージ"]
published: false
---

## はじめに

そもそもなんでKVSを自作しようと思ったかというと、「データベースって中でどうやって動いてるんだろう」という素朴な疑問がきっかけでした。普段なんとなくSQLを書いて、なんとなくデータが保存されて返ってくる。でも、その裏側で何が起きてるのか、実はよくわかってなかったんですよね。

そんなとき、[Code a database in 45 steps](https://trialofcode.org/database/#table-of-contents)という記事を見つけました。実際にこの記事を読み進めながらRDBを作っていたんですが、途中で「もう少し簡易的なものも作ってみたいな」と思ったんですよね。RDBは構造が複雑で学ぶことが多い分、シンプルなKVSなら自分の理解度を確認しながら作れそうだなと。
実際にやってみると、これがめちゃくちゃ勉強になりました。Goの並行処理の排他制御を手を動かして覚えられるし、ファイルI/Oの基本も身につく。Graceful Shutdownの仕組みだって、自分で書いてみると「ああ、こういうことか」と腹落ちします！

今回は約100行くらいのコードで、**スレッドセーフ**で**永続化もできる**KVSを作っていきます。
---

## 設計方針

### Mutex か RWMutex か、それが問題だ

並行アクセスの制御をどうするか。Goだと `sync.Mutex` と `sync.RWMutex` のどっちを使うか、という話になります。

最初は「とりあえず `Mutex` でいいか」と思ったんですが、ちょっと考えてみると、KVSって**読み取りのほうが圧倒的に多い**んですよね。`Mutex` だと、読み取りのときも書き込みと同じように排他ロックを取ってしまう。つまり、誰かが読んでる間は他の人も読めない。

一方で `RWMutex` なら、読み取りは複数のgoroutineで同時にできる。書き込みのときだけ排他的にロックを取ればいい。KVSみたいに「書き込みは時々、読み取りは頻繁」というユースケースには、明らかに `RWMutex` のほうが向いてます。

余談だけど、`RLock()` / `RUnlock()` が読み取りロックで、`Lock()` / `Unlock()` が書き込みロック。最初このネーミングがちょっと紛らわしいなと思ったんですが、慣れると「Rはreadね」とすぐわかるようになります。

### 構造体はシンプルに

```go
type KVS struct {
    data     map[string]string
    mu       sync.RWMutex
    filePath string
}
```

`data` が実際のキーバリューデータ、`mu` がさっき話した排他制御用のミューテックス、`filePath` が永続化先のファイルパス。これだけです。正直なところ、構造体はシンプルなほうがいい。後から「あれ、このフィールド何だっけ」とならないですからね。

---

## 実装

### まずは全体像から

コードの解説に入る前に、まずは完成形を載せておきます。全体で100行ちょっと。これだけでスレッドセーフな永続化KVSが動きます。

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

## コードを読み解いていく

### Get / Set / Delete の基本

#### Get メソッド

```go
func (k *KVS) Get(key string) (string, bool) {
    k.mu.RLock()         // 読み取りロックを取得
    defer k.mu.RUnlock() // 関数終了時にロック解放

    value, exists := k.data[key]
    return value, exists
}
```

`RLock()` を使うことで、複数のgoroutineが同時に `Get()` を呼び出せます。これがパフォーマンス向上のカギ。

ところで、なんで `(string, bool)` の2つを返してるのか気になった人もいるかもしれません。これ、Goでmapを扱うときの定番パターンなんですが、「空文字列が入ってる」のと「キーが存在しない」を区別するためです。片方だけ返すと、空文字が返ってきたときに「値がないのか、空文字が入ってるのか」わからなくなっちゃうんですよね。

#### Set メソッド

```go
func (k *KVS) Set(key, value string) {
    k.mu.Lock()         // 書き込みロックを取得
    defer k.mu.Unlock() // 関数終了時にロック解放

    k.data[key] = value
}
```

書き込みのときは `Lock()` で排他ロック。この間は、他のgoroutineからの読み取りも書き込みもブロックされます。

#### Delete メソッド

```go
func (k *KVS) Delete(key string) {
    k.mu.Lock()
    defer k.mu.Unlock()

    delete(k.data, key)
}
```

削除もデータを変更する操作なので、書き込みロックを取ります。

---

### 永続化のはなし：なぜ gob なのか

永続化の形式、JSONにするか gob にするか、ちょっと悩みました。

JSONは人間が読めるし、他の言語からも扱いやすい。でも今回は「Go内部で完結する永続化」が目的なので、gob を選びました。理由はシンプルで、JSONより速くてファイルサイズも小さいから。Go専用のバイナリ形式なので、型情報もちゃんと保持してくれます。

正直なところ、本番で「デバッグのときに中身を見たい」とか「Pythonからも読みたい」というケースではJSONのほうがいいです。でも今回は学習目的なので、せっかくだからGoっぽいやり方でいきます。

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

ここで「あれ、書き込みしてるのに `RLock()` でいいの？」と思った方、鋭いです。でもよく考えると、`Save()` は `k.data` を**読み取って**ファイルに書いてるだけで、`k.data` 自体は変更してないんですよね。だから読み取りロックで十分。これによって、保存中も `Get()` は普通に呼べます。

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

`Load()` は `k.data` を上書きするので、こっちは書き込みロックが必要です。ファイルが存在しないときは `nil` を返して「新規作成扱い」にしてます。アプリを初めて起動したときにエラーになると面倒ですからね。

---

### Graceful Shutdown：Ctrl+C で落ちてもデータを守る

これ、地味だけど大事な部分です。`Ctrl+C` でプログラムを終了したとき、保存してないデータが消えちゃったら悲しいですよね。`os/signal` を使えば、終了シグナルをキャッチして「終わる前に一仕事」できます。

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

余談だけど、本番環境だと `context.Context` を使ってタイムアウトを設定したほうがいいです。保存処理が何らかの理由で固まったとき、いつまでも待ち続けることになっちゃうので。

---

## 動かしてみよう

### ビルドと実行

```bash
$ go build -o kvs main.go
$ ./kvs
```

### こんな感じで動きます

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

### ファイルも確認してみる

```bash
$ ls -la kvs_data.gob
-rw-r--r--  1 user  staff  67 Feb 21 10:00 kvs_data.gob

$ file kvs_data.gob
kvs_data.gob: data
```

ちゃんとバイナリファイルとして保存されてますね。

---

## もっと遊んでみたい人へ

せっかくなので、発展的なアイデアをいくつか書いておきます。時間があったら試してみてください。

### TTL（有効期限）をつけてみる

Redisっぽく、キーに有効期限をつけられると便利ですよね。

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

### 定期的に自動保存

5分ごとに勝手に保存してくれる仕組み。サーバーとして動かすときに便利です。

```go
go func() {
    ticker := time.NewTicker(5 * time.Minute)
    for range ticker.C {
        kvs.Save()
    }
}()
```

### 複数キーを一気に更新

トランザクション的に複数のキーを原子的に更新する `SetMulti()` とかあると、実用度が上がります。

---

## 最後に：シンプルなものから始めてよかった

ここまで読んでくださってありがとうございます。

最初に書いた通り、もともとは「Code a database in 45 steps」を読みながらRDBを作っていて、その途中で「もっとシンプルなものも作ってみたい」と思ったのがきっかけでした。

結果的に、KVSを先に作ってよかったなと思っています。排他制御やファイル永続化といった基礎的な部分を、複雑なRDBの構造に惑わされずに理解できたので。RDBに戻ったときも「ああ、この部分はKVSでやったやつだ」と繋がる瞬間があって、遠回りのようで近道だったなと。

何か気になることがあれば、コメントで聞いてもらえると嬉しいです。
