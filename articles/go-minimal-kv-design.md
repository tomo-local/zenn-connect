---
title: "Goでシンプルなキーバリューデータベースを自作する"
emoji: "🗄️"
type: "tech"
topics: ["go", "database", "kv"]
published: false
---

## はじめに

データベースの仕組みを理解するために、Goでシンプルなキーバリュー（KV）データベースを実装してみました。この記事では、**ログ構造化ストレージ**を採用したKVデータベースの仕組みと実装について解説します。
プロダクション向けのデータベースではなく、データベースの基本的な仕組みを学ぶための実装です。

## 作るもの

今回作成するのは、以下の機能を持つCLIベースのKVデータベースです。

- **set**: キーと値を保存
- **get**: キーから値を取得
- **delete**: キーを削除
- **list**: 全データをJSON形式で一覧表示

```bash
# 使用例
./kv_cli set name "taro"
./kv_cli get name
./kv_cli list
./kv_cli delete name
```

まずコードの前にこのKVデータベースの設計思想を見ていきましょう。

## ログ構造化ストレージとは

### 従来のアプローチ：update-in-place

一般的なデータの保存方法は、ファイル上の該当箇所を直接書き換える方式です。例えば `name=taro` を `name=jiro` に更新する場合、ファイル内の `taro` の位置を探して `jiro` に上書きします。

この方式はシンプルに見えますが、いくつかの課題があります。

- データのサイズが変わると、前後のデータを移動させる必要がある
- ランダムな位置への書き込み（ランダムI/O）が発生し、パフォーマンスが低下しやすい
- 書き込み途中でクラッシュすると、データが中途半端な状態になるリスクがある

### Append-Only方式

今回採用するのは**Append-Only**（追記のみ）方式です。データの更新や削除であっても、既存のデータを書き換えることはしません。すべての操作をファイルの末尾に追記していきます。

この方式には以下のメリットがあります。

- **書き込みが高速**: 常にファイル末尾への追記なので、シーケンシャルI/Oになる
- **クラッシュリカバリが容易**: 書き込み途中でクラッシュしても、不完全なエントリはファイル末尾にあるだけなので検出・除去しやすい
- **実装がシンプル**: ファイル内の空き領域管理が不要

### トレードオフ：インメモリインデックスが必要

Append-Only方式では、同じキーに対する更新がログの複数箇所に散らばるため、あるキーの最新の値を取得するにはログを最初から全部読む必要があります。これでは読み取りが遅すぎます。

そこで、**メモリ上にインデックス（ハッシュマップ）を持つ**ことで解決します。本実装では、キーに対する最新の値そのものをメモリ上のマップに保持します。これにより、読み取りはO(1)で行えます（その代わり、全データがメモリに載る必要があります）。

```
ログファイル（時系列順に追記）

┌──────────┐
│ set A=10 │  ← 最初の書き込み
├──────────┤
│ set B=20 │
├──────────┤
│ set A=30 │  ← Aを上書き（前のエントリは残る）
├──────────┤
│ del B    │  ← Bの削除（tombstoneを追記）
├──────────┤
│ set C=40 │
└──────────┘

メモリマップ（最新の状態のみ保持）

┌─────┬───────┐
│ Key │ Value │
├─────┼───────┤
│  A  │  30   │
│  C  │  40   │
└─────┴───────┘
※ Bは削除済みなのでマップに存在しない
```

起動時にログファイルを先頭から順に再生し、メモリマップを再構築します。これにより、プロセスを再起動しても前回の状態を復元できます。

## バイナリフォーマットの設計

ログファイルに書き込む各エントリは、バイナリ形式でシリアライズします。

### なぜバイナリ形式か

JSONやCSVなどのテキスト形式ではなくバイナリ形式を選んだ理由は以下の通りです。

- **固定長ヘッダー**: 先頭の9バイトを読めば、後続のキーと値のサイズが確定する。テキスト形式ではデリミタの解析が必要になる
- **デリミタの曖昧さがない**: 値に改行やカンマが含まれていても問題にならない
- **コンパクト**: フィールド名のようなオーバーヘッドがない

### Entryのバイナリレイアウト

1つのEntryは、固定長の9バイトヘッダーと可変長のデータ部で構成されます。

```
┌─────────────────────────────────────────────────────────────┐
│                        1つのEntry                           │
├───────────┬───────────┬──────────┬──────────┬──────────────┤
│  key_len  │  val_len  │ deleted  │   key    │     val      │
│  (4byte)  │  (4byte)  │ (1byte)  │  (可変)  │    (可変)    │
│ uint32 LE │ uint32 LE │  0 or 1  │          │              │
├───────────┴───────────┴──────────┼──────────┴──────────────┤
│       固定ヘッダー: 9バイト       │       可変データ部       │
└──────────────────────────────────┴─────────────────────────┘
```

- **key_len**: キーの長さ（4バイト、リトルエンディアン）
- **val_len**: 値の長さ（4バイト、リトルエンディアン）
- **deleted**: 削除フラグ（1バイト、0=存在, 1=削除済み）
- **key**: キーのバイト列
- **val**: 値のバイト列（deletedが1の場合は空）

### 具体的なバイナリダンプ

`set name "taro"` を実行した場合のバイト列を見てみましょう。

```
key = "name" (4文字), val = "taro" (4文字), deleted = 0

Offset : 00 01 02 03  04 05 06 07  08  09 0A 0B 0C  0D 0E 0F 10
Data   : 04 00 00 00  04 00 00 00  00  6E 61 6D 65  74 61 72 6F
          ~~~~~~~~~~   ~~~~~~~~~~  ~~  ~~~~~~~~~~~   ~~~~~~~~~~~
          key_len=4    val_len=4   del  n  a  m  e    t  a  r  o
                                   =0

合計: 9（ヘッダー）+ 4（key）+ 4（val）= 17バイト
```

削除の場合はどうなるでしょうか。`delete name` を実行すると、値は書き込まず削除フラグだけを立てた**tombstone**（墓標）エントリを追記します。

```
key = "name" (4文字), deleted = 1

Offset : 00 01 02 03  04 05 06 07  08  09 0A 0B 0C
Data   : 04 00 00 00  00 00 00 00  01  6E 61 6D 65
          ~~~~~~~~~~   ~~~~~~~~~~  ~~  ~~~~~~~~~~~
          key_len=4    val_len=0   del  n  a  m  e
                                   =1

合計: 9（ヘッダー）+ 4（key）+ 0（val）= 13バイト
```

ログファイル内では、これらのエントリが連続して並んでいます。

```
ログファイルの中身（連続したバイト列）

┌──── Entry 1: set name "taro" ────┐┌─── Entry 2: set age "25" ───┐
│ 04 00 00 00 04 00 00 00 00 6E 61 ││ 03 00 00 00 02 00 00 00 00  │
│ 6D 65 74 61 72 6F                ││ 61 67 65 32 35              │
└──────────────────────────────────┘└─────────────────────────────┘
  17バイト                            14バイト
```

エントリ間にはデリミタや区切り文字はありません。ヘッダーのサイズ情報だけで次のエントリの境界が分かる仕組みです。

## データの流れを追う：操作ごとの状態変化

ここでは、実際に操作を行ったときにログファイルとメモリマップがどう変化するか、ステップごとに追ってみましょう。

### 初期状態

```
ログファイル: (空)
メモリマップ: {}
```

### 操作1: set name "taro"

メモリマップに追加し、ログファイルに追記します。

```
ログファイル: [name=taro, del=0]
メモリマップ: {"name": "taro"}
```

### 操作2: set age "25"

同様に追加・追記されます。

```
ログファイル: [name=taro, del=0] [age=25, del=0]
メモリマップ: {"name": "taro", "age": "25"}
```

### 操作3: get name

メモリマップから直接取得するため、ログファイルは一切読みません。O(1)のアクセスです。

```
→ 結果: "taro"
ログファイル: (変化なし)
メモリマップ: (変化なし)
```

### 操作4: set name "jiro"（上書き）

メモリマップの値を更新し、ログファイルにも新しいエントリを追記します。古いエントリ（name=taro）はログ内に残りますが、メモリマップは常に最新の値だけを保持します。

```
ログファイル: [name=taro, del=0] [age=25, del=0] [name=jiro, del=0]
                                                    ↑ 末尾に追記
メモリマップ: {"name": "jiro", "age": "25"}
                ↑ 最新の値に更新
```

### 操作5: delete age

削除フラグ付きのtombstoneエントリをログに追記し、メモリマップからキーを削除します。

```
ログファイル: [...] [age, del=1]  ← tombstoneを追記
メモリマップ: {"name": "jiro"}
               ↑ "age"が削除された
```

### プロセス再起動時のログ再生

プロセスを再起動すると、メモリマップは空の状態からスタートします。ログファイルを先頭から順に読み込んで状態を復元します。

```
ログファイルを先頭から順に再生:

  1. name=taro, del=0   → mem["name"] = "taro"
  2. age=25,   del=0   → mem["age"]  = "25"
  3. name=jiro, del=0   → mem["name"] = "jiro"   ← 上書き
  4. age,      del=1   → delete(mem, "age")      ← 削除

再構築されたメモリマップ: {"name": "jiro"}
→ 終了前と同じ状態が復元される
```

このように、ログを先頭から順に再生するだけで、最新の状態を正確に復元できます。これがログ構造化ストレージの基本的な仕組みです。

## アーキテクチャ

ここまでの概念を踏まえて、このKVデータベースの全体像を見てみましょう。3つの主要コンポーネントで構成されています。

```
┌─────────────────────────────────────────────────────┐
│                      KV Store                       │
│                                                     │
│  ┌──────────────┐    set/del     ┌───────────────┐  │
│  │  Memory Map  │ ◄──────────── │    CLI Layer   │  │
│  │ map[string]  │ ──────────►   │  (flag.Args)   │  │
│  │   []byte     │    get/list   └───────────────┘  │
│  └──────┬───────┘                                   │
│         │ 起動時: ログ再生で再構築                      │
│         │ 書込時: メモリとログを同期更新                 │
│  ┌──────┴───────┐                                   │
│  │     Log      │  ← Append-Only File               │
│  │ ┌──────────┐ │                                   │
│  │ │  Entry   │ │  ← Binary Encode/Decode           │
│  │ └──────────┘ │                                   │
│  └──────────────┘                                   │
└─────────────────────────────────────────────────────┘
```

1. **Entry**: データのバイナリエンコード/デコードを担当
2. **Log**: ファイルへの永続化を担当（Append-Only方式）
3. **KV**: メモリ上のマップとログを組み合わせたKVストア本体

では、それぞれの実装を見ていきましょう。

## 実装

### 1. Entry - データのシリアライズ

Entryはキーバリューのペアをバイナリ形式でエンコード/デコードする構造体です。

```go
type Entry struct {
	key     []byte
	val     []byte
	deleted bool
}
```

#### エンコード処理

先ほど定義したバイナリフォーマットに従って、Entryの各フィールドを1つのバイト列に詰めます。まずヘッダー（9バイト）を書き込み、続けてキーと値のデータを書き込みます。`deleted=true` の場合は `val_len` を0にし、値のデータは書き込みません。

```go
func (ent *Entry) Encode() []byte {
	// 初期のデータ構造を定義 (key)4byte+（val)4byte+(deleted)1byte+keyサイズ+valサイズ
	data := make([]byte, 4+4+1+len(ent.key)+len(ent.val))
	// keyの文字数
	binary.LittleEndian.PutUint32(data[0:4], uint32(len(ent.key)))
	// keyの値
	copy(data[9:], ent.key)
	// deletedの値
	if ent.deleted {
		data[8] = 1
	} else {
		data[8] = 0
		// valの文字数
		binary.LittleEndian.PutUint32(data[4:8], uint32(len(ent.val)))
		copy(data[9+len(ent.key):], ent.val)
	}

	return data
}
```

#### デコード処理

デコードはエンコードの逆の処理です。まず固定長の9バイトヘッダーを読み取ります。ヘッダーからキーと値のサイズが分かるので、続けてそのサイズ分だけデータを読み取ります。

```go
func (ent *Entry) Decode(r io.Reader) error {
	var header [9]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return err
	}

	keyLen := int(binary.LittleEndian.Uint32(header[0:4]))
	valLen := int(binary.LittleEndian.Uint32(header[4:8]))
	deleted := header[8]

	data := make([]byte, keyLen+valLen)
	if _, err := io.ReadFull(r, data); err != nil {
		return err
	}

	ent.key = data[:keyLen]
	if deleted != 0 {
		ent.deleted = true
	} else {
		ent.deleted = false
		ent.val = data[keyLen:]
	}

	return nil
}
```

### 2. Log - ファイル永続化

LogはAppend-Onlyファイルへの読み書きを担当する構造体です。

```go
type Log struct {
	FileName string
	fp       *os.File
}
```

`Open`では`os.O_RDWR|os.O_CREATE`フラグを指定してファイルを開きます。`O_RDWR`は読み書き両方を許可し、`O_CREATE`はファイルが存在しない場合に新規作成します。起動時はこのファイルからログを読み取り、操作時には末尾に追記するため、読み書き両方が必要です。

```go
func (log *Log) Open() (err error) {
	log.fp, err = os.OpenFile(log.FileName, os.O_RDWR|os.O_CREATE, 0o644)
	return err
}

func (log *Log) Close() error {
	return log.fp.Close()
}
```

`Write`はEntryをエンコードしてファイルに書き込みます。ファイルポインタは自然に末尾へ進むため、常にAppend（追記）になります。

```go
func (log *Log) Write(ent *Entry) error {
	_, err := log.fp.Write(ent.Encode())
	return err
}
```

`Read`はファイルからEntryを1件読み取ります。ファイル末尾（EOF）に到達した場合は`eof=true`を返し、KVストアのログ再生ループに終了を通知します。

```go
func (log *Log) Read(ent *Entry) (eof bool, err error) {
	err = ent.Decode(log.fp)
	if err == io.EOF {
		return true, nil
	}
	return false, err
}
```

### 3. KV - メインのKVストア

KVストアは、メモリ上のマップ（高速アクセス用）とログファイル（永続化用）を組み合わせた構造体です。

```go
type KV struct {
	log Log
	mem map[string][]byte
}
```

#### 起動時の処理（Open）

先ほど「データの流れを追う」セクションで見たログ再生の処理がここで行われています。ログファイルをEOFまで順に読み込み、各エントリの内容に従ってメモリマップを構築します。`deleted`フラグが立っているエントリはマップから削除、それ以外はマップに追加します。

```go
func (kv *KV) Open() error {
	if err := kv.log.Open(); err != nil {
		return err
	}

	kv.mem = map[string][]byte{}
	for {
		ent := Entry{}
		eof, err := kv.log.Read(&ent)
		if err != nil {
			return err
		}

		if eof {
			break
		}

		if ent.deleted {
			delete(kv.mem, string(ent.key))
		} else {
			kv.mem[string(ent.key)] = ent.val
		}
	}
	return nil
}
```

#### Get - 値の取得

メモリマップから直接取得するため、ログファイルは一切参照しません。O(1)の高速アクセスです。

```go
func (kv *KV) Get(key []byte) ([]byte, bool, error) {
	val, ok := kv.mem[string(key)]
	return val, ok, nil
}
```

#### Set - 値の保存

メモリマップを更新し、ログファイルにエントリを追記します。ただし、同じキーに同じ値がすでに存在する場合は書き込みをスキップする最適化が入っています。`!exist || !bytes.Equal(prev, val)` の条件により、値が変わっていない場合は不要なログ書き込みを避けています。

```go
func (kv *KV) Set(key []byte, val []byte) (bool, error) {
	prev, exist := kv.mem[string(key)]
	kv.mem[string(key)] = val
	updated := !exist || !bytes.Equal(prev, val)
	if updated {
		if err := kv.log.Write(&Entry{key: key, val: val}); err != nil {
			return false, err
		}
	}
	return updated, nil
}
```

#### Delete - 値の削除

Append-Onlyの性質を壊さずにデータを削除するために、**tombstone**（墓標）という手法を使います。実際にログからデータを消すのではなく、削除フラグ付きのエントリを追記します。メモリマップからはキーを削除するため、以後のGetではキーが見つからなくなります。

```go
func (kv *KV) Del(key []byte) (bool, error) {
	_, deleted := kv.mem[string(key)]
	if deleted {
		if err := kv.log.Write(&Entry{key: key, deleted: true}); err != nil {
			return false, err
		}
		delete(kv.mem, string(key))
	}
	return deleted, nil
}
```

#### List - 一覧表示

メモリマップの内容をJSON形式で出力します。

```go
func (kv *KV) List() ([]byte, error) {
	if kv.mem == nil {
		return []byte("{}"), nil
	}

	exportData := make(map[string]string)
	for key, val := range kv.mem {
		exportData[key] = string(val)
	}

	jsonData, err := json.MarshalIndent(exportData, "", "  ")
	if err != nil {
		return nil, err
	}

	return jsonData, nil
}
```

### 4. CLI - コマンドラインインターフェース

CLIは`flag`パッケージを使ったシンプルな実装です。

```go
func main() {
	database := KV{}
	database.log.FileName = getDataBasePath()

	flag.Parse()
	args := flag.Args()

	if len(args) < 1 {
		fmt.Printf("Error: expect more data size:%d\n", len(args))
		os.Exit(1)
	}

	database.Open()
	defer database.Close()

	switch args[0] {
	case "get":
		get(database, args[1:])
	case "set":
		set(database, args[1:])
	case "delete":
		del(database, args[1:])
	case "list":
		list(database, args[1:])
	default:
		fmt.Println("Error: unknown params")
		os.Exit(1)
	}
}
```

## 使い方

### ビルド

```bash
cd app
go build -o kv_cli .
```

### 基本操作

```bash
# 値を保存
./kv_cli set user1 "Alice"
./kv_cli set user2 "Bob"

# 値を取得
./kv_cli get user1
# 出力: key:user1, value:Alice

# 一覧表示
./kv_cli list
# 出力:
# {
#   "user1": "Alice",
#   "user2": "Bob"
# }

# 削除
./kv_cli delete user1
```

### データベースファイルのパス

環境変数`DATABASE_PATH`でデータファイルのパスを変更できます。

```bash
DATABASE_PATH=/tmp/mydb ./kv_cli set key value
```

### ログファイルの中身を確認する

`xxd`コマンドを使うと、ログファイルのバイナリの中身を確認できます。先ほどのバイナリフォーマットの解説と見比べてみてください。

```bash
xxd data.log | head
```

## 制限事項と発展

この実装はあくまで学習用であり、実用的なデータベースにするにはいくつかの課題があります。

- **ログコンパクションがない**: 上書きや削除を繰り返してもログファイルは大きくなる一方です。実際のデータベース（例：Bitcask）では、古いエントリを定期的にマージ・圧縮するコンパクション処理を行います
- **全データがメモリに載る必要がある**: 値そのものをメモリに保持しているため、大規模なデータセットには向きません。ファイルオフセットだけをメモリに保持する方式や、LSM-tree方式にすることでこの制約を緩和できます
- **クラッシュ安全性が不十分**: `fsync`による書き込み保証やチェックサムによるデータ整合性検証がないため、書き込み途中のクラッシュでデータが壊れる可能性があります
- **並行制御がない**: 複数のプロセスから同時にアクセスした場合の排他制御がありません

## まとめ

Goでシンプルなキーバリューデータベースを実装しました。この実装を通じて、以下のことを学びました。

- **Append-Onlyログ**はディスク容量と引き換えに、書き込みの高速さと実装のシンプルさを手に入れる設計
- **インメモリインデックス**はメモリと引き換えに、O(1)の読み取り速度を実現する仕組み
- **Tombstone**によりAppend-Onlyの性質を壊さずにデータの論理削除を実現できること
- **バイナリエンコード**により固定長ヘッダーでエントリ境界を判別できる効率的なデータ形式

実際のデータベースは非常に複雑ですが、このような基本的な実装から始めることで、データベースの仕組みを理解する良い学習になります。バイナリエンコードやAppend-Onlyログなど基礎的な技術を使っているので学びになりました。また、他の記事で続きを書こうと思います。

## GitHub

https://github.com/tomo-local/kv_database

## 参考

- [Build Your Own Database From Scratch](https://build-your-own.org/database/)
- [Log-structured Storage](https://en.wikipedia.org/wiki/Log-structured_file_system)
