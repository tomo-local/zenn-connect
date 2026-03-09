---
title: "Goでシンプルなキーバリューデータベースを自作する"
emoji: "🗄️"
type: "tech"
topics: ["go", "database", "kv", "cli"]
published: true
---

## はじめに

データベースの仕組みを理解するために、Goでシンプルなキーバリュー（KV）データベースを実装してみました。この記事では、ログ構造化ストレージを採用したKVデータベースの仕組みと実装について解説します。

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

## アーキテクチャ

このKVデータベースは3つの主要コンポーネントで構成されています。

```
┌─────────────────────────────────────────────┐
│                   KV Store                  │
│  ┌─────────────────┐  ┌──────────────────┐  │
│  │   Memory Map    │  │       Log        │  │
│  │ (map[string][]  │  │  (Append-only    │  │
│  │     byte)       │  │     File)        │  │
│  └─────────────────┘  └──────────────────┘  │
│                           │                 │
│                           ▼                 │
│                  ┌──────────────────┐       │
│                  │      Entry       │       │
│                  │ (Binary Encode/  │       │
│                  │     Decode)      │       │
│                  └──────────────────┘       │
└─────────────────────────────────────────────┘
```

1. **Entry**: データのバイナリエンコード/デコードを担当
2. **Log**: ファイルへの永続化を担当
3. **KV**: メモリ上のマップとログを組み合わせたKVストア本体

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

#### バイナリフォーマット

データは以下の形式でファイルに保存されます。

| フィールド | サイズ |
| --- | --- |
| key_len | 4byte |
| val_len | 4byte |
| deleted | 1byte |
| key | 可変 |
| val | 可変 |

- **key_len**: キーの長さ（4バイト、リトルエンディアン）
- **val_len**: 値の長さ（4バイト、リトルエンディアン）
- **deleted**: 削除フラグ（1バイト、0=存在, 1=削除）
- **key**: キーのデータ
- **val**: 値のデータ（deletedが1の場合は空）

#### エンコード処理

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

Logはファイルへの読み書きを担当します。Append-Only方式を採用しています。

```go
type Log struct {
	FileName string
	fp       *os.File
}

func (log *Log) Open() (err error) {
	log.fp, err = os.OpenFile(log.FileName, os.O_RDWR|os.O_CREATE, 0o644)
	return err
}

func (log *Log) Close() error {
	return log.fp.Close()
}

func (log *Log) Write(ent *Entry) error {
	_, err := log.fp.Write(ent.Encode())
	return err
}

func (log *Log) Read(ent *Entry) (eof bool, err error) {
	err = ent.Decode(log.fp)
	if err == io.EOF {
		return true, nil
	}
	return false, err
}
```

**Append-Only方式のメリット:**
- 書き込みが高速（常にファイル末尾に追記）
- データの整合性が保ちやすい
- クラッシュリカバリが容易

### 3. KV - メインのKVストア

KVストアは、メモリ上のマップ（高速アクセス用）とログファイル（永続化用）を組み合わせています。

```go
type KV struct {
	log Log
	mem map[string][]byte
}
```

#### 起動時の処理（Open）

起動時にログファイルから全エントリを読み込み、メモリマップを再構築します。

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

メモリマップから直接取得するため、O(1)の高速アクセスが可能です。

```go
func (kv *KV) Get(key []byte) ([]byte, bool, error) {
	val, ok := kv.mem[string(key)]
	return val, ok, nil
}
```

#### Set - 値の保存

値が変更された場合のみログに書き込みます。

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

削除フラグ付きのエントリをログに追記し、メモリマップからも削除します。

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

`flag`パッケージを使用してCLIを実装しています。

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

## まとめ

Goでシンプルなキーバリューデータベースを実装しました。

- **Entry**: バイナリエンコード/デコードでデータを効率的に保存
- **Log**: Append-Only方式で高速な書き込みを実現
- **KV**: メモリマップで高速な読み取りを実現しつつ、ログで永続化

実際のデータベースは非常に複雑ですが、このような基本的な実装から始めることで、データベースの仕組みを理解する良い学習になります。
まだ実際のDBには程遠いですが、バイナリエンコードやAppend-Onlyログなど基礎的な技術を使っているので学びになりました。また、他の記事で続きを書こうと思います。

## GitHub

https://github.com/tomo-local/kv_database

## 参考

- [Build Your Own Database From Scratch](https://build-your-own.org/database/)
- [Log-structured Storage](https://en.wikipedia.org/wiki/Log-structured_file_system)
