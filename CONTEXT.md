# monorepo

由多個 Go 微服務構成，以 monorepo 管理各服務的 git submodule。

服務之間有**兩種**通訊方式，兩者並存且用途不同：

- **非同步**：透過 RabbitMQ 的 **job.exchange** 傳遞 **Job**，用於排程觸發的工作
- **同步**：`telegram` → `bookkeeping` 的 gRPC 直連，用於使用者輸入需要立即回應的場合

此外所有服務都以 library 形式引用 `core`。

本檔案定義跨服務的共用語彙與關係。服務內部實作細節請看各自的 `CLAUDE.md`。

## Language

**Job（任務）**  
`center` 依 cron 發起的一個工作單元，以 proto 訊息發布至 **job.exchange**，由單一 consumer 服務處理。  
_Avoid_：task、排程（「排程」專指 cron spec 本身，不指被發出的那則訊息）

**job.exchange**  
全系統唯一的 topic exchange，位於 vhost `job`。所有跨服務訊息都經過它，沒有第二個 exchange。

**Routing key**  
決定訊息落到哪個 queue。命名為 `<service>`（如 `exchange_rate`）或 `<service>.<結果>`（如 `telegram.success`、`telegram.error`）。  
各 queue 以 `<service>.#` wildcard binding 訂閱，因此新增 `<service>.*` 形式的 routing key 不需改動 binding。

**Topology**  
exchange、queue、binding 的宣告集合，由 `core/rabbitmq` 在服務啟動時建立。  
producer 只需宣告 exchange（`LoadBasicTopology`），consumer 需要完整的 queue binding（`LoadCompleteTopology`）。

**Envelope**  
跨服務訊息的通用封裝（定義於 `rabbitmq/message.proto`），承載 **EnvelopeType** 與 Data 兩部分。  
用於接收端必須依型別決定如何解讀內容的場合；單一用途的訊息（如 CurrencyPair、CleanInbox）直接以自己的 proto 傳遞，不包 Envelope。  
_Avoid_：wrapper、payload（Data 才是 payload）

**EnvelopeType**  
Envelope 的判別欄位，接收端據此決定 Data 的解讀與格式化方式。  
新增跨服務訊息型別時在此擴充，而非新增 routing key。

**CurrencyPair**  
base 貨幣 + counter 貨幣清單 + **CurrencyType** 的組合。  
由 `center` 在排程設定中指定，`exchange_rate` 消費。

**CurrencyType**  
`FIAT` 或 `CRYPTO`，決定 `exchange_rate` 查詢哪個外部 API。  
這是分派的唯一依據。

**設定鍵（Setting key）**  
存放在 Upstash Redis 的一筆設定值。  
服務啟動時由 `core/config` 一次性載入為記憶體中的設定，執行期不再回查 Redis。  
_Also known as_：proto 上的型別名為 `XxxEnvKey`（`scheduler/env/kv.proto`），屬歷史名稱，刻意保留不改；enum 的**值名**即 Redis 鍵名（`:` 轉為 `_`）。  
_Avoid_：環境變數（真正的 OS 環境變數只有 `REDIS_HOST` / `REDIS_PORT` / `REDIS_PASSWORD` 三個，用來連上 Redis 本身）

**Service prefix**  
設定鍵的命名空間。  
`GLOBAL:*` 為全服務共用（RabbitMQ、Logger、時區等），`<PREFIX>:*` 為單一服務專屬（如 `TELEGRAM:*`）。  
服務只載入 `GLOBAL` 加自己的 prefix，看不到其他服務的設定。

**Contract repo**  
`scheduler`，所有 proto 的單一真實來源。  
經由 BSR（`buf.build/leo84927-proto/scheduler`）發布，各服務以 `go get` 引用產生的 Go 程式碼，改動它會同時影響多個服務。  
_Avoid_：scheduler service（`scheduler` 不是一個會執行的服務，只是文件倉；真正的排程器是 `center`）

**Worker**  
consumer 服務註冊到 `core/initialize.App` 的訊息處理函式。  
一個服務可註冊多個 worker；`center` 是唯一沒有 worker 的服務。

## 服務職責

| 服務 | 角色 | 職責 |
|---|---|---|
| `center` | 唯一 producer | 依 cron 發起 **Job**，發布至 **job.exchange**。不消費任何訊息。 |
| `exchange_rate` | consumer + producer | 消費 **CurrencyPair**，查詢外部匯率 API，將結果包成 **Envelope** 轉發給 `telegram`。 |
| `telegram` | consumer + gRPC client | 消費 **Envelope**，依 **EnvelopeType** 格式化後送至 Telegram chat；接收 Telegram webhook，並以 gRPC 直接呼叫 `bookkeeping` 寫入使用者輸入的記帳資料。 |
| `bookkeeping` | consumer + gRPC server | 記帳服務。**全系統唯一可存取資料庫的服務**，資料來源為 `telegram` 經 gRPC 傳入的使用者輸入。 |
| `core` | library | 共用基礎建設，以 `go get github.com/leo84927/core` 引用，非獨立執行的服務。 |
| `scheduler` | **Contract repo** | proto 文件倉，見上方定義。 |
| `docker` | 本地開發 | docker compose 設定，僅供本地啟動整套架構；生產環境不使用容器。 |

## Relationships

- 一個 **Job** 對應一個 **Routing key**，並由恰好一個服務消費
- **job.exchange** 之下每個服務有一個 queue，以 `<service>.#` binding 訂閱
- **Envelope** 承載一個 **EnvelopeType**；**CurrencyPair** 承載一個 **CurrencyType**
- 每個服務讀取 `GLOBAL` 加自己的一個 **Service prefix**
- 所有服務都依賴 **Contract repo** 與 `core`
- `telegram` 是 `bookkeeping` 的 gRPC client；這是全系統唯一的服務間同步呼叫。兩端都以 `otelgrpc` 的
  StatsHandler instrument，`traceparent` 隨 gRPC metadata 傳遞，因此一次使用者記帳輸入在 Grafana 上是
  單一 trace：webhook span → gRPC 呼叫端 span → `bookkeeping` 服務端 span

### 訊息流向

| 發送者 | Routing key | 接收 queue | 訊息格式 |
|---|---|---|---|
| `center` | `exchange_rate` | exchange_rate.queue | CurrencyPair proto |
| `exchange_rate` | `telegram.success` | telegram.queue | Envelope（ExchangeRate） |
| `exchange_rate` | `telegram.error` | telegram.queue | Envelope（錯誤訊息） |

```
                    job.exchange (topic)
                              │
          ┌───────────────────┼───────────────────┐
          │                   │                   │
    exchange_rate         telegram.*         bookkeeping
          │                   │                   │
          ▼                   ▼                   ▼
 exchange_rate.queue    telegram.queue    bookkeeping.queue
bind: exchange_rate.#  bind: telegram.#  bind: bookkeeping.#
```

bookkeeping.queue 已綁定，但目前尚無 producer 發布訊息至該 routing key。

## 系統級不變條件

- **時區**：所有服務統一為 `Asia/Taipei`，由 `GLOBAL` 設定鍵提供
- **設定來源**：Upstash Redis，啟動時載入（見 **設定鍵**、**Service prefix**）
- **資料庫存取**：只有 `bookkeeping` 可以連資料庫，其他服務要存取資料須經 `bookkeeping`（非同步走 MQ，同步走 gRPC）
- **proto 來源**：只有 **Contract repo**，不在各服務內自行定義跨服務訊息型別
- **trace 跨服務不斷開**：非同步走 AMQP headers（由 `core` 的 producer / consumer 負責），同步走 gRPC
  metadata（由兩端的 `otelgrpc` StatsHandler 負責）。接收端的日誌一律要帶 handler 收到的 `ctx`，
  否則日誌寫不出 `trace_id` / `span_id`，在 Grafana 上就和 span 脫鉤
- **投遞語意**：MQ 上的訊息交付為 **at-least-once** —— 一則訊息可能被執行**一次以上**。發布端（`center`）與所有消費端都受此約束

## 超時預算

### 對外呼叫

| 位置                                             | 值      | 重試              | 承載機制                                                                                        |
|-------------------------------------------------|---------|------------------|------------------------------------------------------------------------------------------------|
| `exchange_rate` → 向第三方查詢匯率                 | 5s      | X                | `http.Client.Timeout`；`main` 建**一個** client 傳給兩個 adapter                                  |
| `telegram` → Telegram Bot API（getMe）           | 5s      | X                | 同一個 client 的 `Timeout`；失敗**不重試、直接不啟動**，重試交給 systemd                              |
| `telegram` → Telegram Bot API（sendMessage）     | 單次 5s  | **V** `{3, 20s}` | `http.Client.Timeout` ＋ `BotSender.Send` 內部的 backoff                                         |
| `telegram` → `bookkeeping` gRPC                 | 5s      | X                | 呼叫端 `context.WithTimeout`；gRPC 自動把 deadline 傳給 `bookkeeping`                           |
| `bookkeeping` consumer（`KeepAliveHandler`）     | 5s      | X                | 呼叫端 `context.WithTimeout`（這條路沒有上游 deadline 可繼承）                                   |
| MariaDB 連線建立                                 | 5s      | **V** `{3, 20s}` | 值為 `GLOBAL_MARIADB_TIMEOUT`；重試由 `GLOBAL_MARIADB_CONN_MAX_RETRIES`／`CONN_MAX_ELAPSED_TIME` |
| MariaDB socket 讀取                             | 5s      | X                | 設定鍵 `GLOBAL_MARIADB_READ_TIMEOUT`                                                           |
| MariaDB socket 寫入                             | 5s      | X                | 設定鍵 `GLOBAL_MARIADB_WRITE_TIMEOUT`                                                          |
| Redis 連線建立                                   | 5s      | **V** `{3, 30s}` | 值為 `DialTimeout`，`core/config` 寫死                                                          |
| Redis 讀取／寫入                                 | 各 5s   | X                | `ReadTimeout`／`WriteTimeout`，`core/config` 寫死                                                |
| RabbitMQ 發布                                   | **無**  | **V** `{3, 5s}`  | `ConnectionManager.Config`；單次發布沒有獨立 timeout，只有重試總預算                             |

### 關機等待

SIGTERM 之後的順序：errgroup 收攤 → `RabbitmqCM.Close()` → OTLP flush。後兩段嚴格串行。

| 步驟 | 上限 |
|---|---|
| consumer drain（`wg.Wait()`） | 不設上限，但所有對外呼叫皆 ctx-aware，取消即返回 |
| `telegram` webhook `Server.Shutdown` | 5s |
| `bookkeeping` `GracefulStop`，逾時後 `Stop()` | 5s |
| AMQP `Connection.CloseDeadline` | 5s |
| OTLP log exporter `Shutdown` | 5s |
| OTLP trace exporter `Shutdown` | 5s |

## Flagged ambiguities

- **`scheduler` 一詞有兩個意思**：`Contract repo` 的 repo 名稱，以及 `center` 內部的 cron 元件（`center/scheduler/`）。提到跨服務的 proto 時用 **Contract repo**，提到 cron 時明確寫 `center/scheduler`。
