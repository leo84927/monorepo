# ADR-0002：訊息確認契約與投遞語意

- **狀態**：已採用
- **日期**：2026-08-26
- **相關**：[issue #22](https://github.com/leo84927/monorepo/issues/22)、[issue #8](https://github.com/leo84927/monorepo/issues/8)（併發模型）、[issue #9](https://github.com/leo84927/monorepo/issues/9)（requeue 政策）、[issue #17](https://github.com/leo84927/monorepo/issues/17)（關機路徑）、[issue #7](https://github.com/leo84927/monorepo/issues/7)（架構深化修正計劃）

## 脈絡

`CONTEXT.md` 的系統級不變條件寫著「MQ 上的訊息交付為 **at-least-once**」。**在本 ADR 之前，這句話是錯的。**

`core/rabbitmq` 的 handler 契約原本是：

```go
type MsgHandler func(context.Context, Message, PublishHandler) (requeue bool, err error)
```

而三個 consumer 服務（`exchange_rate`、`telegram`、`bookkeeping`）的 handler 都是同一個形狀 —— 用 `go` 把工作丟出去，然後立刻回傳 `(false, nil)`。`handleDelivery` 讀到 `err == nil`，於是走 `Ack`。broker 收到 Ack 就把訊息刪掉，**而此時工作才剛開始**。

這不是 at-least-once，是 **at-most-once**：process 在工作途中崩潰或被 SIGTERM 砍掉，那則訊息已經從 broker 上消失，永遠不會被重送。

同一個根因還生出另外三個症狀，過去都被當成獨立的怪現象：

- **prefetch 從未生效。** `Qos(1)` 限制的是「未確認訊息數」。既然每則訊息都立刻被 Ack，未確認訊息數永遠是 0，broker 從來不會因為 prefetch 而停止推送。真正的併發度是無上限的。
- **trace 破碎。** `handleDelivery` 的 `defer span.End()` 在 handler 回傳時就跑了，而工作正在另一個 goroutine 上。per-message 的子 span 掛在一個已經結束的 parent 上。
- **goroutine 拿到死 ctx。** span 結束、`handleDelivery` 返回，工作 goroutine 手上的 `ctx` 已無意義。

`requeue` 這個回傳值也從來沒有被真正用過 —— 它的值恆為 `false`，因為錯誤根本傳不回來。

## 決策

### 一、work-then-Ack，併發歸 `core`

`core` 的 consumer 自己為每一則訊息開 goroutine，服務端的 worker 一律**同步執行**：

```go
type MsgHandler func(context.Context, Message, PublishHandler) error
```

worker 回傳代表工作真的做完了，此時才 `Ack`。這是**破壞性變更**：`(requeue bool, err error)` 收斂成只回傳 `error`。

**不做 worker pool。** prefetch 就是併發度旋鈕：broker 最多送出 prefetchCount 則未確認訊息，in-flight goroutine 的數量因此被 broker 夾住。worker pool 會變成第二個旋鈕，而兩個旋鈕必然要互相對齊，對齊錯了就是「pool 滿了但 broker 還在推」或「prefetch 給了但 pool 吃不下」。

### 二、prefetch 定 4，寫死在 `core`

`core/rabbitmq/consumer.go` 的 `prefetchCount = 4`，三個 consumer 服務同值，不走設定鍵。

值定 4 而非 1：現在未確認訊息數真的會長起來了，`Qos(1)` 等於強制序列處理，把剛拿回來的併發能力又關掉。定 4 而非更大：三個服務跑在同一台 e2-micro 上（見 `CONTEXT.md` 的部署架構），in-flight 的工作幾乎都在等外部 I/O，4 足以蓋住延遲又不會讓單一服務吃掉整台機器的記憶體。

不走設定鍵：這個值與程式碼的併發假設綁在一起（例如「所有對外呼叫皆 ctx-aware」），能在 Redis 上被改成 400 的旋鈕不是旋鈕，是地雷。要調整就是改那一行、重新部署。

### 三、否認一律 `Nack(false, false)`，且**不做錯誤分類**

`core` 不匯出任何 sentinel error、不定義任何錯誤型別，handler 回傳什麼錯誤都一視同仁。

`multiple=false`：per-message goroutine 併發確認，批次確認會誤殺別的訊息。

`requeue=false`：一旦 `err` 第一次真的會被讀到，`requeue=true` 就第一次可能造成無限迴圈 —— 永久性失敗（protojson unmarshal 失敗、未知 `CurrencyType`、找不到對應 handler）requeue 回去只會再失敗一次，而且是立刻。要區分暫時性與永久性，就要有一套分類機制；要讓 requeue 安全，就要有重試次數上限；要有上限，就要有地方存放次數 —— 這條路的終點是 dead-letter exchange，不是一個 bool。

保留 `Nack` 的 `requeue` 參數而非改用 `Reject`：日後真的接上 DLX 時，訊息會依 `x-dead-letter-exchange` 進到死信佇列，這一行不必動。零成本的選項。

**關機途中的失敗是唯一的例外：不否認，留著不確認。** ctx 一取消，所有 ctx-aware 的對外呼叫會立刻回 `context.Canceled`，那是「還沒做完」而不是「做了但失敗」。此時若照常 `Nack(false, false)`，在沒有 DLX 的情況下等於把訊息刪掉 —— 每一次關機都會打破一次 at-least-once，drain 等了半天卻在最後一步把訊息丟了。留著不確認就好，broker 會在 AMQP channel 關閉時把未確認的訊息重新入隊，這正是 drain 要買到的東西。

反過來，**工作已完成之後才收到取消，仍然要 Ack**：否則已經做完的工作會被重送、白白多執行一次。判斷點是 handler 有沒有回傳錯誤，不是 ctx 的狀態。

### 四、per-message 路徑 recover panic

worker panic 只讓「該則訊息」失敗（走 Nack），process 存活。原本 `initialize` 的 `graceful` 只包住 errgroup 的頂層 goroutine，per-message goroutine 不在它的保護範圍內 —— 一則訊息 panic 會帶走整個 process，連同其餘 in-flight 的訊息一起陪葬。

panic 現場只存在於 `debug.Stack()`：eris 是在 `recover` 這一刻才擷取堆疊，抓到的是 `runHandler` 的 defer，不是 panic 那一行。所以現場堆疊直接寫進錯誤訊息裡，再由 `eris.Errorf` 補上 rabbitmq 的框（ADR-0001 的約束）。

### 五、確認／否認失敗改走 `logger.Error`

`Ack` / `Nack` 失敗原本是裸 `log.Println`，寫不出 `trace_id`，在 Grafana 上與 span 脫鉤。改走 ADR-0001 的入口 `logger.Error(ctx, msg, err)`，帶的是 handler 收到的 ctx。

### 六、drain 用區域性 WaitGroup，排在 AMQP channel 關閉之前

`subscribeAndWait` 內宣告區域 `sync.WaitGroup`，每則訊息 `wg.Add(1)`。**不設 drain timeout** —— drain timeout 只把「卡住」變成「卡住然後照樣被砍」，實際上限由 systemd 的 `TimeoutStopSec` 提供，而讓 drain 一定收得回來的責任在「所有對外呼叫皆 ctx-aware 且有 timeout」（issue #17 的產出，見 `CONTEXT.md` 的超時預算）。

**執行順序是 drain 先、關 channel 後。** `defer wg.Wait()` 寫在 `defer ch.Close()` 之後，LIFO 下 `wg.Wait()` 先跑。反過來的話，in-flight 的 Ack 會打在一個已關閉的 AMQP channel 上、全數失敗，訊息一律被 broker 重送 —— 等於白等一場 drain。issue #22 的驗收條件原文寫「drain 排在 channel 關閉之後」，指的是 `defer` 敘述在**原始碼中的位置**；若照執行順序解讀，drain 的保護會歸零。測試 `TestWaitForConsume_DrainsInFlightBeforeClosingChannel` 把這個順序釘死。

區域變數而非 `Consumer` 欄位：每次 `subscribeAndWait`（含重連後的新一輪）都是一組全新的 goroutine，新一輪不該等到上一輪的殘骸。

`context` 的取消語意不動：ctx 取消後 handler 仍會收到已取消的 ctx，由 handler 自己的 ctx-aware 呼叫負責立刻返回。

### 六之一、發布的 confirm 等待改吃 ctx

`PublishWithDeferredConfirm` 之後的 `confirm.Wait()` 沒有 ctx、沒有 deadline，會無限期等 broker 回 confirm。改用 `WaitContext(ctx)`。

這在本 ADR 之前不會出事：handler 立刻回傳，發布跑在一個逃逸出去的 goroutine 上，關機不等它。現在 handler 同步執行、**發布跑在 drain 裡面**，而 drain 刻意不設上限 —— 決策六的前提是「所有對外呼叫皆 ctx-aware」，`confirm.Wait()` 是這個前提唯一的破口。broker 收下發布卻不回 confirm（例如 TCP 連線還在的網路分區），`wg.Wait()` 就永遠不會返回；而能解開這個死結的 `ConnectionManager.Close()` 排在 errgroup 收攤**之後**，救不了。結果是 systemd 強殺，連 OTLP flush 都輪不到，關機當下沒有任何診斷資訊。

`WaitContext` 不引入新的 timeout 值 —— 上限沿用呼叫端的 ctx，`CONTEXT.md` 記載的「單次發布沒有獨立 timeout，只有重試總預算」不變。

### 七、AMQP 連線關閉帶 5s deadline

`ConnectionManager.Close()` 改用 `Connection.CloseDeadline(time.Now().Add(5s))`。amqp091 的 `Close()` 會無限期等 broker 回 close-ok，而它在關機順序上排在 OTLP flush **前面** —— 卡在這裡的話，關機當下最需要的診斷資訊全部送不出去。

### 八、log 與 trace 兩個 OTLP exporter **各自** 5s

原本兩者共用同一個 5s 的 ctx。共用的話 log flush 慢就會把 trace 餓死，而關機出問題時最需要看的正是 trace。

### 九、不改動任何 RabbitMQ 設定

queue arguments 不可變：對已存在的 durable queue 用不同 arguments 重新宣告，broker 會回 `406 PRECONDITION_FAILED`，服務起不來。本次變更完全不碰 `InitTopology` 的宣告內容。

## 被否決的替代方案

**worker pool 收進 `core`，併發度另設一個旋鈕。** 否決：見決策一。兩個旋鈕必須互相對齊，而 prefetch 這個旋鈕已經由 broker 強制執行，pool 只是把同一件事再做一次、而且做得比較弱。

**併發留在各服務，但改成正確等待（handler 內 `go` + `wg.Wait()`）。** 否決：等於要求三個服務各自實作一次同一段併發與 recover 邏輯，而且錯了不會有人發現 —— 現況正是這樣壞掉的。`bookkeeping` 的 `KeepAliveHandler` 已經是同步簽名，直接就是新契約的參考實作。

**`core` 提供 sentinel error 讓 handler 標記暫時性／永久性失敗。** 否決（暫時）：分類本身不難，難的是分類之後要做什麼。requeue 回去而沒有次數上限就是無限迴圈；有上限就要有地方存次數，那個地方應該是 broker（DLX + TTL），不是 `core`。在 DLX 落地之前，分類是一個沒有出口的抽象。等 DLX 這張票排上來時再加，屆時是純增量的改動。

**同一張票把 DLQ / `x-dead-letter-exchange` 一起做掉。** 否決：DLX 要改 queue arguments，而 queue arguments 不可變 —— 對已存在的 durable queue 重新宣告會拿到 `406 PRECONDITION_FAILED`。這需要一次有計劃的 queue 遷移（新 queue、雙寫、切換、刪舊），與本票「不改動任何 RabbitMQ 設定」的邊界正面衝突，必須是獨立的一張票。

**設 drain timeout。** 否決：見決策六。drain timeout 不會讓卡住的工作變快，只會讓它在被 systemd 砍掉之前先被我們自己砍一次，而且砍的時候訊息已經 in-flight、Ack 送不出去，結果與沒有 drain 相同。

**prefetch 走設定鍵。** 否決：見決策二。

## 後果

- **`CONTEXT.md` 的「投遞語意：at-least-once」第一次成為事實。** 訊息在工作真正完成後才被 broker 刪除；處理途中崩潰或關機的訊息由 broker 自動重送。
- **關機時 in-flight 的訊息會被重送。** 它們在 broker 上仍是未確認狀態，channel 一關就重新入隊。這是刻意的 —— 也是 at-least-once 的直接後果。
- **重複執行第一次成為真實風險。** 過去 at-most-once 的實際行為讓「一則訊息可能被執行一次以上」停留在紙上，handler 的冪等性從未被檢驗過。現在它會發生 —— 崩潰、關機、Ack 失敗都會導致重送。各服務 handler 的冪等性需要逐一檢視，不在本票範圍內。
- **四個服務暫時無法編譯。** `MsgHandler` 的簽名是破壞性變更；monorepo 根目錄有一個 gitignore 的 `go.work`，四個服務對 `core` 的版本要求在本機完全不生效、一律吃本地目錄。這是刻意的，由 issue #23 起的後續票逐一修復。**本次不打 tag。**
- prefetch 第一次真的生效，未確認訊息數會長到 4。broker 端的 queue depth 與 unacked 指標從此有意義。
- per-message 的 span 與工作同壽，trace 不再掛在已結束的 parent 上。
- 一則訊息的 panic 不再帶走 process。
- Ack / Nack 失敗的日誌帶得到 `trace_id`。
- 關機路徑的每一段等待都有上限（drain 除外，其上限由 systemd 提供）：AMQP close 5s、OTLP log flush 5s、OTLP trace flush 5s，各自獨立。
- **drain 的上限第一次真的存在。** 決策六的「不設 drain timeout」只有在所有對外呼叫都會被 ctx 取消時才成立，決策六之一補上了唯一的破口。各服務 handler 內部的對外呼叫是否都 ctx-aware，由 issue #17 的產出（見 `CONTEXT.md` 的超時預算）與後續各服務的票負責。
- `core` 仍然沒有錯誤分類機制。永久性失敗的訊息會被直接丟棄（`Nack(false, false)` 且無 DLX），**訊息就此消失**。這是明知的取捨：在 DLX 落地之前，丟棄比無限迴圈安全。
