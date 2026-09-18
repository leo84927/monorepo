# ADR-0003：設定載入回傳純值

- **狀態**：已採用
- **日期**：2026-08-26
- **相關**：[issue #23](https://github.com/leo84927/monorepo/issues/23)、[issue #11](https://github.com/leo84927/monorepo/issues/11)（介面形狀）、[issue #13](https://github.com/leo84927/monorepo/issues/13)（重試預算）、[issue #7](https://github.com/leo84927/monorepo/issues/7)（架構深化修正計劃）

## 脈絡

`core/config` 原本的介面是「一個 `map[string]string` ＋ 九個套件層變數 ＋ 一段沒有寫下來的呼叫順序」：

```go
config.InitFromRedis(ctx, "TELEGRAM")   // 寫 EnvMap、GrafanaEndpoint、TimeZone、Loc…
config.ServiceName = config.EnvMap[env.TelegramEnvKey_TELEGRAM_SERVICE_NAME.String()]
config.LoadBasicRabbitMQ()              // ← 讀 config.ServiceName，所以上面那行必須排在它前面
config.LoadCompleteTopology(queue)
```

痛點不是「介面醜」，而是**呼叫順序與必要前置條件沒有任何型別在記錄，弄錯全部靜默**：

- `LoadBasicRabbitMQ` 讀 `config.ServiceName`。那行指派漏了或排錯位置，AMQP 連線的 `connection_name` 就是空字串，沒有任何錯誤。
- 漏呼叫 `LoadBasicRabbitMQ` 的後果最嚴重：`GetRabbitMQConfig().Config == nil` → `initialize.New` 的 `if` 整段跳過 → `connReady` 的 `make()` 也在那個 `if` 裡，於是它是 **nil channel** → `ConsumerExecution` 第一件事就是 `select { case <-worker.connReady: … }`，**永久阻塞到 ctx 取消**。服務啟動成功、webhook 收得到、gRPC 打得到，但 MQ 那一半完全沒在跑，訊息全部堆在 queue 沒人領。
- 六處 `strconv.Atoi` / `time.ParseDuration` 失敗後 `log.Printf` 再塞一個寫死的預設值（5／20s／3／20s／3／20s）。Redis 上把 `20s` 寫成 `20`，服務照樣起來，用的是程式碼裡的值而不是設定裡的值。
- 缺鍵完全不檢查。`EnvMap[k]` 對不存在的鍵回空字串，所以「漏了一筆設定」與「那筆設定是空的」在型別上無法區分。
- `log.Fatalf` 讓整段邏輯無法被測試。
- `InitFromRedis` 建立的 Redis 連線從未關閉（連線洩漏），而設定只在啟動時讀一次、執行期不再回查 —— 那條連線之後永遠不會被用到。

`Load` 要收斂這些，第一個要回答的問題是：**它要不要順手把 logger 也開起來？** 誘因很直接 —— `Load` 內部就能用 `logger.Error` 記錄自己的失敗，而不是 `log.Fatalf`。

## 決策

### 一、`Load(ctx, Spec) (Settings, error)`，`Settings` 是純值

單一入口，取代九個套件層變數與七個匯出函式（`InitFromRedis`、`LoadMariaDbConfig`、`LoadBasicRabbitMQ`、`LoadBasicTopology`、`LoadCompleteTopology`、`GetRabbitMQConfig`、`GetMariaDbConfig`）。

`Load` 做「讀 Redis + `GLOBAL:*` → `<PREFIX>:*` 覆寫 + 驗證 + 型別轉換 + `time.LoadLocation`」，**零全域寫入、零 logger／tracer 初始化**。Redis 連線由 `Load` 自建，`defer cm.Close()` 在返回前關閉。

### 二、logger 初始化**不**吸進 `Load`

`logger.Config` 的三個欄位（`ServiceName`、`Endpoint`、`AuthHeader`）**全都是設定鍵**。所以 logger 必然在設定之後 —— 這是真實的雞生蛋，也是 `InitFromRedis` 只能用 `log.Fatalf`（而不是 `logger.Error`）的根本原因：設定載入失敗的那一刻，能寫日誌的東西還不存在。

吸進來的好處拿不到、壞處無法迴避：

- 一個叫 `Load` 的函式要開 OTLP 連線，並且產生一個必須配對的 `Close` 義務 —— 這個義務會**傳染給四個 `main.go`**。
- 測試解析邏輯時每次都會試著連 Grafana。
- 雞生蛋沒有被解決，只是被搬進 `Load` 內部：它仍然得先讀完那三個鍵才能開 logger，在那之前的失敗仍然只能寫 stderr。

副作用與其生命週期管理留在 `initialize.New` / `app.Close` 同一層。`Load` 失敗的呼叫端寫法是 `fmt.Fprintln(os.Stderr, err)` 然後 return —— 這不是退步，而是誠實地承認：**logger 還沒開的階段，就只有 stderr 可用。**

同理，`initialize.New` 保留為獨立的一層（`Load` 不直接回傳 `*App`）：合併會讓 `core/config` 與 `core/initialize` 互相 import，而且 `Load` 就退化成上面否決掉的「有 `Close` 義務的 Load」。

### 三、`Spec` 是能力宣告，不是鍵清單

```go
type Spec struct {
	Prefix         string       // "TELEGRAM"，對應 Redis 的 <PREFIX>:* 命名空間
	ServiceNameKey fmt.Stringer // 服務名放在哪個鍵
	MariaDB        bool         // 只有 bookkeeping 為 true
	Queue          *QueueKeys   // nil = 只當 producer；non-nil = consumer，需完整 topology
	ServiceKeys    []fmt.Stringer
}
```

各服務真正的差異不是「要哪些鍵」，而是 `LoadMariaDbConfig` / `LoadBasicTopology` / `LoadCompleteTopology` 的**呼叫與否** —— 原本用一段順序敏感的呼叫序列表達。逐鍵列舉（`Keys []EnvKey`）的版本會讓 `Load` 退化成「包了 Redis 的 map getter」：介面複雜度等於實作複雜度，排序與組裝原封不動留在呼叫端，等於沒解決問題。

鍵型別是 `fmt.Stringer` 而非某個 enum 型別：`GlobalEnvKey`、`CenterEnvKey`、`ExchangeRateEnvKey`、`TelegramEnvKey`、`BookkeepingEnvKey` 是 Contract repo 裡**五個不同的 Go 型別**，沒有共同的 enum 型別，唯一共通介面是 `String()`。

`Prefix` 保持顯式而不從 `ServiceNameKey.String()` 用 `TrimSuffix("_SERVICE_NAME")` 推導：那是靠命名慣例的巧技，改個鍵名就靜默壞掉 —— 正是這批改動要消滅的東西。

### 四、RabbitMQ 設定改為值型別，「服務啟動成功卻不消費任何訊息」變成不可表達

`Settings.RabbitMQ.Config` 是 `rabbitmq.Config` 而非 `*rabbitmq.Config`。指標的唯一用途是讓 `initialize.New` 用 `!= nil` 判斷「`LoadBasicRabbitMQ` 有沒有被呼叫過」，而那正是脈絡裡最嚴重的靜默 bug 來源。四個服務全部用 MQ，`Load` 保證會填，nil 從此不該可表達。

連帶：`initialize.New` 的 MQ 初始化**改成無條件執行**，`connReady` 一定會被 `make`，nil channel 永久阻塞的路徑消失。Consumer 的建立條件改為 `MsgHandler != nil && settings.RabbitMQ.Queue != nil`。

兩者必須**同時有或同時沒有**，不一致時 `New` 直接回 error。`Spec.Queue` 與 `MsgHandler` 是同一件事（「這個服務是 consumer」）的兩半、宣告在不同的地方，而對不起來的兩個方向都是靜默的：

- **有 handler 沒 queue**：安靜地不建 Consumer，就是把「服務啟動成功卻不消費任何訊息」換一個入口重新引進；原本的行為則是留給 `Run` 在 nil `Consumer` 上 panic、由 `graceful` 的 recover 接住後服務結束 —— 雖然大聲，但錯誤訊息是一個 nil pointer dereference 的堆疊，看不出真正的原因。
- **有 queue 沒 handler**：`ConnectionExecution` 跳過 `InitTopology`，queue 與 binding 從未建立，producer 發來的訊息在 exchange 上找不到 binding 而被丟棄，**兩端都不會有任何日誌**。

不改成「由 topology 是否有 queue 決定要不要 `InitTopology`」：那會讓 producer-only 的 `center` 開始宣告 exchange，是一個新的 broker 互動，與 ADR-0002 決策九「不改動任何 RabbitMQ 設定」衝突（arguments 對不上就是 `406`，服務起不來）。

冗餘的 `ServiceQueue` 欄位砍掉，改成 `Queue *rabbitmq.Queue`：原本同一個值存兩份（`Topology.Queues[0]` 與 `ServiceQueue`），而 `ServiceQueue.Name` 唯一的讀者就是「要不要建 Consumer」這個判斷 —— `Spec.Queue` 已經宣告了這件事。

### 五、`initialize.New(ctx, settings, app)`：`settings` 是位置參數

不是 `App` 的欄位。決定性差別是編譯器擋不擋得住漏傳：塞進 `App{Settings: …}` 的版本漏填就是 zero value，`RabbitMQ.Config` 空白，靜默 bug 原封不動地回來 —— 只是換了觸發方式。位置參數漏傳直接編譯失敗。

### 六、錯誤語意：`errors.Join`、Redis 端真實鍵名、缺鍵報錯／空值放行

一次報齊全部問題，不自訂 error 型別 —— `Load` 失敗就是啟動失敗，不會有呼叫端做 `errors.As`。

錯誤訊息帶 **Redis 端的真實鍵名**（`TELEGRAM:TOKEN`，不是 enum 值名 `TELEGRAM_TOKEN`），看到錯誤就知道去 Upstash 補哪一筆。命名空間只有 `GLOBAL` 與 `Prefix` 兩種，所以轉換不能只換第一個底線 —— `EXCHANGE_RATE_API_KEY` 那樣會變成不存在的 `EXCHANGE:RATE_API_KEY`，錯誤訊息本身就成了誤導。

**「鍵不存在」報錯、「鍵存在但值為空」放行。** 兩個鍵的空值是刻意且有語意的：`core/mariadb` 用 `if d.TLSCaPEM != ""` 決定要不要開 TLS（本地開發不開），`telegram/router` 用空的 webhook secret 放行（避免設定 secret 前直接中斷既有 webhook）。而 raw 的 key 全部來自 `Scan`，所以 `v, ok := raw[k]` 的 `ok` 精確等於「Redis 有沒有這筆」。

於是 **Redis 鍵的存在本身就是宣告**：在 Upstash 明確放一筆空值 =「我知道有這個設定，我選擇不啟用」；整筆不存在 =「你漏了」。這比在 `Spec` 多維護一份 `OptionalKeys` 清單乾淨。

**不偵測「Redis 有但 `Spec` 沒宣告」的多餘鍵。** 打錯字已被上面的判準抓到（`TELEGRAM:TOKENN` 打錯 → 正確的 `TELEGRAM:TOKEN` 不存在 → 報 missing），剩下的增量價值只有「找出死掉的鍵」，是清理需求不是正確性需求。而且 `GLOBAL:*` 是共用命名空間，14 個 `MARIADB_*` 鍵對 `center`／`telegram`／`exchange_rate` 全都「多餘」，做在 GLOBAL 上必然誤報。

### 七、六處型別轉換的預設值 fallback 取消，改報錯

留這個後門會讓 `Load` 的契約變成「回 nil error 不代表設定是對的」，和整批修正的立論正面衝突。

兩條規則在數值鍵上自然合流：空值對字串鍵合法，對數值／duration 鍵則會在轉換階段失敗並報錯 —— 不需要額外規則。

**這是本 ADR 唯一會改變現有部署行為的一項**：Upstash 上這六個鍵的值必須是合法格式，否則對應服務啟動失敗。

### 八、服務專屬設定以 `map[string]string` 回傳

`core` 只保證 `Spec.ServiceKeys` 列出的鍵存在，命名與型別由服務端自組具名結構加建構子（`telegram/config.New(settings.Service)`）。

不用泛型加 struct tag：為了消滅四個服務合計約 12 行機械指派，卻要在共用函式庫引入 reflect 與一套 tag DSL，而 tag 裡的鍵名是字串 —— **反而失去原本靠 proto enum 拿到的型別保護**。

### 九、測試打未匯出的純函式 `parse`

`parse(raw map[string]string, spec Spec) (Settings, error)` 是內部 seam：覆寫順序、缺鍵聚合、六處型別轉換全在它裡面，不碰 Redis。

**不注入 `Source` interface**：設定來源只有 Redis 一個，一個 adapter 只是假想的 seam，而且會把「先自己建 Redis 連線」的義務推給四個 `main.go`。`Load` 的 Redis 往返不測 —— 那要靠 Upstash pre-flight 驗證，在測試裡塞一個假的 Redis 只會測到假的東西。

### 十、重試預算收進 `rabbitmq.Config`，三組分開

| 預算 | 值 | 來源 | 用在 |
|---|---|---|---|
| 連線重連 | 設定鍵 | `GLOBAL:RABBITMQ_CONN_MAX_*` | `WatchConnAndRetry` |
| 發布重試 | `{3, 5s}` | 寫死在 `NewConnectionManager` | `PublishWithRetry` |
| 消費重連 | `{5, 20s}` | 寫死在 `NewConnectionManager` | `WaitForConsume` |

後兩組原本是 `PublishWithRetry` 與 `NewConsumer` 的**尾綴位置引數**，由呼叫端逐點提供 —— 於是逐點分歧：`exchange_rate` 傳 `3, 5*time.Second`（正確），`center` 三處傳 `3, 10` —— 字面 `10` 給 `time.Duration` 就是 **10 奈秒**，重試預算在第一次嘗試就用盡。同一個問題在 codebase 裡有兩個不同答案，沒有任何線索能判斷哪個是刻意的。

收成未匯出欄位之後，呼叫端無從提供，那三個錯誤的呼叫點直接消失。簽名同步簡化：

```go
func (cm *ConnectionManager) PublishWithRetry(ctx context.Context, exchange, key string, body []byte) error
func (cm *ConnectionManager) NewConsumer(queue, tag string) *Consumer
type PublishHandler func(ctx context.Context, exchange, key string, body []byte) error
```

`PublishHandler` 必須跟著收斂 —— 它是交給**每一個** `MsgHandler` 的型別，不同步就立刻分歧。`Consumer.MaxElpasedTime` 的拼字錯誤隨欄位消失一併解決。

三組分開而不共用欄位：消費重連預算真正的意思是「這個服務願意容忍 broker 斷線多久才自我了結」（超過就讓 `WaitForConsume` 回 error → errgroup → 整個服務結束），是偽裝成重試次數的**可用性參數**，和「單次發布失敗要重試幾次」語意完全不同。

不走設定鍵：這兩個值與程式碼的行為假設綁在一起，理由同 ADR-0002 的 prefetch。

## 被否決的替代方案

**`Load` 順手初始化 logger 與 tracer。** 否決：見決策二。核心理由是 `Close` 義務的傳染性 —— 一個叫 `Load` 的函式不該讓四個呼叫端各背一個 `defer`。

**`Spec` 用 `Keys []EnvKey` 逐鍵列舉。** 否決：見決策三。`Load` 會退化成淺模組。

**保留 getter 過渡（`config.WebhookSecret()`）。** 否決：getter 版本只是把變數換成函式，全域狀態還在、測試還是得寫全域，零收益。各服務全域變數一次拿掉。

**`Settings.Service` 用泛型加 struct tag 綁進具名結構。** 否決：見決策八。

**注入 `Source` interface 讓測試替換設定來源。** 否決：見決策九。

**偵測多餘的鍵。** 否決：見決策六。`GLOBAL:*` 是共用命名空間，必然誤報。

**只把第一個底線換成冒號來推導 Redis 鍵名。** 否決：`EXCHANGE_RATE` 這個雙字命名空間會被切錯，錯誤訊息指向一個不存在的鍵。改為以 `GLOBAL` 與 `Spec.Prefix` 為界切分。

## 後果

- **`Load` 回 nil error 現在真的代表「設定是對的」。** 缺鍵、格式錯誤、時區無效都會在啟動時一次報齊，帶 Redis 端真實鍵名。
- **「設定漏載入 → 服務啟動成功卻不消費任何訊息」在型別上不可表達。** 值型別加無條件初始化消滅了 nil channel 永久阻塞的路徑。
- **Upstash 上六個鍵的格式從此是硬性要求。** `GLOBAL:RABBITMQ_CONN_MAX_RETRIES`（int）、`GLOBAL:RABBITMQ_CONN_MAX_ELAPSED_TIME`（duration）、`GLOBAL:RABBITMQ_TOPOLOGY_MAX_RETRIES`（int）、`GLOBAL:RABBITMQ_TOPOLOGY_MAX_ELAPSED_TIME`（duration）、`GLOBAL:MARIADB_CONN_MAX_RETRIES`（int）、`GLOBAL:MARIADB_CONN_MAX_ELAPSED_TIME`（duration）。格式錯誤不再靜默 fallback，而是啟動失敗。這是本 ADR 唯一改變現有部署行為的一項，部署前需 pre-flight 驗證。
- **Redis 連線洩漏修掉了。** `Load` 自建自關。
- **`center` 的三個 job 各有一個 10 奈秒的重試預算 bug 隨欄位消失而蒸發**，不需要逐點修正。
- **`core` 的 breaking 表面積擴大**：`config` 套件 9 個變數 ＋ 7 個函式全滅、`initialize.New` 簽名改、`PublishWithRetry` / `NewConsumer` / `PublishHandler` 簽名改，疊在 ADR-0002 的 `MsgHandler` 之上。四個服務仍然無法編譯，由後續票逐一修復。**本次不打 tag。**
- **`Load` 失敗仍然只能寫 stderr**，不會進 Grafana。這是決策二的直接後果，也是誠實的：logger 還沒開的階段就只有 stderr 可用。設定錯誤的可觀測性靠部署流程（systemd journal）而非 OTLP。
- `Settings` 裡 `ServiceName` 出現三次（頂層、`Logger`、`RabbitMQ.Config`）。這不是漂移 —— 頂層是真實來源，另兩份是各 adapter 自己的設定複本，`Load` 一次填好。
- `GLOBAL:BOOKKEEPING_SOCK_FILE_PATH` 是 GLOBAL 鍵、`telegram` 與 `bookkeeping` 共讀，因此不列進 `ServiceKeys`，由 `Load` 當 GLOBAL 必要鍵驗證並以 `Settings.GrpcSockPath` 回傳。`center` 與 `exchange_rate` 也會要求它存在（它們不讀，但驗證是無條件的）。
- `CONTEXT.md` 不需要改動：`Spec` / `Settings` 是 `core` 的實作型別，不是跨服務語彙；既有的「設定鍵」與「Service prefix」兩則定義在這批改動後全部仍然成立。
- **這一條在 [issue #29](https://github.com/leo84927/monorepo/issues/29) 之後部分不成立（本 ADR 的決策不變）**：`CONTEXT.md` 的 **Topology** 條目原本點名 `LoadBasicTopology` / `LoadCompleteTopology`，本 ADR 把這兩個函式刪掉，該條目因此必須改述，改述時引用了 `Spec.Queue`。「設定鍵」與「Service prefix」兩則定義仍然不必動。詳見 `docs/adr/0004-core-v2-module-path.md`。
