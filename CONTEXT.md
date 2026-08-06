# monorepo

個人 side-project，由多個 Go 微服務構成，以 monorepo 管理各服務的 git submodule。核心約束：**服務之間不直接呼叫，一律透過 RabbitMQ 訊息傳遞**；唯一的例外是所有服務都以 library 形式引用 `core`。

本檔案定義跨服務的共用語彙與關係。服務內部實作細節請看各自的 `CLAUDE.md`。

## Language

**Job（任務）**
`center` 依 cron 發起的一個工作單元，以 proto 訊息發布至 **job.exchange**，由單一 consumer 服務處理。
_Avoid_：task、排程（「排程」專指 cron spec 本身，不指被發出的那則訊息）

**job.exchange**
全系統唯一的 topic exchange，位於 vhost `job`。所有跨服務訊息都經過它，沒有第二個 exchange。

**Routing key**
決定訊息落到哪個 queue。命名為 `<service>`（如 `exchange_rate`、`email`）或 `<service>.<結果>`（如 `telegram.success`、`telegram.error`）。各 queue 以 `<service>.#` wildcard binding 訂閱，因此新增 `<service>.*` 形式的 routing key 不需改動 binding。

**Topology**
exchange、queue、binding 的宣告集合，由 `core/rabbitmq` 在服務啟動時建立。producer 只需宣告 exchange（`LoadBasicTopology`），consumer 需要完整的 queue binding（`LoadCompleteTopology`）。

**Envelope**
跨服務訊息的通用封裝（定義於 `rabbitmq/message.proto`），承載 **EnvelopeType** 與 Data 兩部分。用於接收端必須依型別決定如何解讀內容的場合；單一用途的訊息（如 CurrencyPair、CleanInbox）直接以自己的 proto 傳遞，不包 Envelope。
_Avoid_：wrapper、payload（Data 才是 payload）

**EnvelopeType**
Envelope 的判別欄位，接收端據此決定 Data 的解讀與格式化方式。新增跨服務訊息型別時在此擴充，而非新增 routing key。

**CurrencyPair**
base 貨幣 + counter 貨幣清單 + **CurrencyType** 的組合。由 `center` 在排程設定中指定，`exchange_rate` 消費。

**CurrencyType**
`FIAT` 或 `CRYPTO`，決定 `exchange_rate` 查詢哪個外部 API。這是分派的唯一依據。

**設定鍵（Setting key）**
存放在 Upstash Redis 的一筆環境變數。服務啟動時由 `core/config` 一次性載入為記憶體中的設定，執行期不再回查 Redis。
_Avoid_：環境變數（真正的 OS 環境變數只有 `REDIS_HOST` / `REDIS_PORT` / `REDIS_PASSWORD` 三個，用來連上 Redis 本身）

**Service prefix**
設定鍵的命名空間。`GLOBAL:*` 為全服務共用（RabbitMQ、Logger、時區等），`<PREFIX>:*` 為單一服務專屬（如 `TELEGRAM:*`）。服務只載入 `GLOBAL` 加自己的 prefix，看不到其他服務的設定。

**Contract repo**
`scheduler`，所有 proto 的單一真實來源。經由 BSR（`buf.build/leo84927-proto/scheduler`）發布，各服務以 `go get` 引用產生的 Go 程式碼。改動它會同時影響多個服務。
_Avoid_：scheduler service（`scheduler` 不是一個會執行的服務，只是文件倉；真正的排程器是 `center`）

**Worker**
consumer 服務註冊到 `core/initialize.App` 的訊息處理函式。一個服務可註冊多個 worker；`center` 是唯一沒有 worker 的服務。

## 服務職責

| 服務 | 角色 | 職責 |
|---|---|---|
| `center` | 唯一 producer | 依 cron 發起 **Job**，發布至 **job.exchange**。不消費任何訊息。 |
| `exchange_rate` | consumer + producer | 消費 **CurrencyPair**，查詢外部匯率 API，將結果包成 **Envelope** 轉發給 `telegram`。 |
| `telegram` | consumer | 消費 **Envelope**，依 **EnvelopeType** 格式化後送至 Telegram chat；並負責 Telegram webhook 的接收。 |
| `email` | consumer | 消費 **Job**，定期清理個人郵件，或對消費紀錄信件做特殊處理後供 `bookkeeping` 使用。 |
| `bookkeeping` | consumer | 記帳服務。**全系統唯一可存取資料庫的服務**，資料來源為使用者的 Telegram 輸入與 `email` 的處理結果。 |
| `core` | library | 共用基礎建設，以 `go get github.com/leo84927/core` 引用，非獨立執行的服務。 |
| `scheduler` | **Contract repo** | proto 文件倉，見上方定義。 |
| `docker` | 本地開發 | docker compose 設定，僅供本地啟動整套架構；生產環境不使用容器。 |

## Relationships

- 一個 **Job** 對應一個 **Routing key**，並由恰好一個服務消費
- **job.exchange** 之下每個服務有一個 queue，以 `<service>.#` binding 訂閱
- **Envelope** 承載一個 **EnvelopeType**；**CurrencyPair** 承載一個 **CurrencyType**
- 每個服務讀取 `GLOBAL` 加自己的一個 **Service prefix**
- 所有服務都依賴 **Contract repo** 與 `core`

### 訊息流向

| 發送者 | Routing key | 接收 queue | 訊息格式 |
|---|---|---|---|
| `center` | `exchange_rate` | exchange_rate.queue | CurrencyPair proto |
| `center` | `email` | email.queue | CleanInbox proto |
| `exchange_rate` | `telegram.success` | telegram.queue | Envelope（ExchangeRate） |
| `exchange_rate` | `telegram.error` | telegram.queue | Envelope（錯誤訊息） |

```
                            job.exchange (topic)
                                   │
         ┌─────────────────┬───────┴───────┬─────────────────┐
         │                 │               │                 │
    exchange_rate        email         telegram.*       bookkeeping
         │                 │               │                 │
         ▼                 ▼               ▼                 ▼
 exchange_rate.queue  email.queue    telegram.queue   bookkeeping.queue
bind: exchange_rate.# bind: email.#  bind: telegram.# bind: bookkeeping.#
```

bookkeeping.queue 已綁定，但目前尚無 producer 發布訊息至該 routing key。

## 系統級不變條件

- **時區**：所有服務統一為 `Asia/Taipei`，由 `GLOBAL` 設定鍵提供
- **設定來源**：Upstash Redis，啟動時載入（見 **設定鍵**、**Service prefix**）
- **資料庫存取**：只有 `bookkeeping` 可以連資料庫，其他服務要資料一律走訊息
- **proto 來源**：只有 **Contract repo**，不在各服務內自行定義跨服務訊息型別

## Flagged ambiguities

- **Consul → Redis 遷移未收尾**：`scheduler` 的 proto 檔仍名為 `consul/kv.proto`、enum 仍稱 `XxxEnvKey`，`core/consul/` 也還在（已標註棄用）。實際的設定來源已是 Upstash Redis。命名尚未跟上，讀到 `consul` 字樣時一律理解為 **設定鍵** 機制。
- **`scheduler` 一詞有兩個意思**：`Contract repo` 的 repo 名稱，以及 `center` 內部的 cron 元件（`center/scheduler/`）。提到跨服務的 proto 時用 **Contract repo**，提到 cron 時明確寫 `center/scheduler`。
- **`email` 與 `bookkeeping` 之間的資料傳遞方式未定案**：`email` 對消費紀錄信件做特殊處理後應交給 `bookkeeping`，但 bookkeeping.queue 目前無 producer，這條路徑尚未實作。
