# Examples の使い方

すべてのコマンドは `zig/` ディレクトリから実行する。

```bash
cd /path/to/orch/zig
zig build          # 全バイナリをビルド
```

ビルド済みバイナリは `zig-out/bin/` に生成される。

---

## 1. simple

単一〜複数ノードのゴシップクラスタを形成し、5秒ごとにクラスタサイズとリーダーを表示する。

### 環境変数

| 変数 | 説明 | デフォルト |
|------|------|-----------|
| `ORCH_CLUSTER_TOKEN` | クラスタ識別トークン（必須、非ゼロ整数） | — |
| `ORCH_ADDR` | このノードのゴシップアドレス | `0.0.0.0:7946` |
| `ORCH_SEEDS` | カンマ区切りのシードアドレス | — |
| `ORCH_NODE_ID` | ノード識別子（省略時は自動生成） | — |
| `ORCH_SERVICE` | サービス名 | `simple` |

### 単一ノード

```bash
ORCH_CLUSTER_TOKEN=123 zig-out/bin/simple
```

出力例：
```
info: orch-simple: starting addr=0.0.0.0:7946 service=simple
info: orch: TCP listening on 0.0.0.0:7946
info: orch: UDP bound on 0.0.0.0:7946
info: raft: TCP listener on port 7947
info: orch-simple: node started, id=019df643074d-00011049-orch
info: raft: became leader, term=1
info: cluster size=1 leader=true
```

### 複数ノード（3ノードクラスタ）

ターミナルを3つ開いて実行する。

**ノード1（シード）:**
```bash
ORCH_CLUSTER_TOKEN=123 \
ORCH_ADDR=127.0.0.1:7946 \
  zig-out/bin/simple
```

**ノード2:**
```bash
ORCH_CLUSTER_TOKEN=123 \
ORCH_ADDR=127.0.0.1:7947 \
ORCH_SEEDS=127.0.0.1:7946 \
  zig-out/bin/simple
```

**ノード3:**
```bash
ORCH_CLUSTER_TOKEN=123 \
ORCH_ADDR=127.0.0.1:7948 \
ORCH_SEEDS=127.0.0.1:7946 \
  zig-out/bin/simple
```

ノードが結合するとクラスタサイズが増え、リーダー選出が行われる。  
`Ctrl+C` で停止すると残りのノードが障害検知してサイズを減らす。

---

## 2. loadbalancer

HTTPリクエストをバックエンドサーバ群へラウンドロビンで振り分ける。  
ORCH のゴシップでバックエンドを自動検出する。

### 構成

```
クライアント → lb (ポート8080) → server×N (ポート808X)
                  ↕ ゴシップ(7950)     ↕ ゴシップ(7946+)
```

### 環境変数（server）

| 変数 | 説明 | デフォルト |
|------|------|-----------|
| `ORCH_CLUSTER_TOKEN` | クラスタトークン（必須） | — |
| `PORT` | HTTP リスンポート | `8080` |
| `ORCH_ADDR` | ゴシップアドレス（`PORT+1000` が自動設定される） | `0.0.0.0:9080` |
| `ORCH_SEEDS` | シードアドレス | — |
| `ORCH_SERVICE` | サービス名 | `http-backend` |

### 環境変数（lb）

| 変数 | 説明 | デフォルト |
|------|------|-----------|
| `ORCH_CLUSTER_TOKEN` | クラスタトークン（必須） | — |
| `PORT` | HTTP リスンポート | `8080` |
| `ORCH_ADDR` | ゴシップアドレス | `0.0.0.0:7950` |
| `ORCH_SEEDS` | シードアドレス（バックエンドのゴシップアドレス） | — |
| `ORCH_SERVICE` | 検出対象のサービス名 | `http-backend` |
| `ORCH_LB_SERVICE` | LB 自身のサービス名 | `lb` |

### 動かし方

**ターミナル1 — バックエンドサーバ1:**
```bash
ORCH_CLUSTER_TOKEN=123 \
PORT=8081 \
ORCH_ADDR=127.0.0.1:9081 \
ORCH_SERVICE=http-backend \
  zig-out/bin/lb-server
```

**ターミナル2 — バックエンドサーバ2:**
```bash
ORCH_CLUSTER_TOKEN=123 \
PORT=8082 \
ORCH_ADDR=127.0.0.1:9082 \
ORCH_SEEDS=127.0.0.1:9081 \
ORCH_SERVICE=http-backend \
  zig-out/bin/lb-server
```

**ターミナル3 — ロードバランサ:**
```bash
ORCH_CLUSTER_TOKEN=123 \
PORT=8080 \
ORCH_ADDR=127.0.0.1:7950 \
ORCH_SEEDS=127.0.0.1:9081,127.0.0.1:9082 \
ORCH_SERVICE=http-backend \
  zig-out/bin/lb
```

**ターミナル4 — リクエスト送信:**
```bash
# 繰り返しリクエストを投げてラウンドロビンを確認
for i in $(seq 1 10); do curl -s http://localhost:8080/hello; done
```

出力例（`node=` が交互に変わる）：
```
node=019df6...-orch requests=1 leader=false cluster_size=2 path=GET /hello HTTP/1.1
node=019df7...-orch requests=1 leader=true  cluster_size=2 path=GET /hello HTTP/1.1
node=019df6...-orch requests=2 leader=false cluster_size=2 path=GET /hello HTTP/1.1
```

### バックエンドの動的追加

サーバを追加してもゴシップで自動検出される：
```bash
ORCH_CLUSTER_TOKEN=123 \
PORT=8083 \
ORCH_ADDR=127.0.0.1:9083 \
ORCH_SEEDS=127.0.0.1:9081 \
ORCH_SERVICE=http-backend \
  zig-out/bin/lb-server
```

しばらくするとLBが新しいバックエンドへもリクエストを振り分け始める。

### バックエンドを止めたときの挙動

いずれかのサーバを `Ctrl+C` で停止すると、ゴシップの障害検知（デフォルト数秒）でクラスタから除外され、LBは残りのバックエンドだけへリクエストを送る。

---

## ビルドターゲット一覧

```bash
zig build              # 全バイナリビルド
zig build run-simple   # simple を直接実行（ORCH_CLUSTER_TOKEN が必要）
```

| バイナリ | ソース |
|---------|--------|
| `zig-out/bin/simple` | `examples/simple/main.zig` |
| `zig-out/bin/lb-server` | `examples/loadbalancer/server/main.zig` |
| `zig-out/bin/lb` | `examples/loadbalancer/lb/main.zig` |
