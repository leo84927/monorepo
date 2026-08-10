# ADR-0001：錯誤日誌以單一 `exception.stacktrace` 字串輸出，並在入口修正 caller

- **狀態**：已採用
- **日期**：2026-08-07
- **相關**：[issue #2](https://github.com/leo84927/monorepo/issues/2)、[issue #1](https://github.com/leo84927/monorepo/issues/1)（caller 來源位置）

## 脈絡

`core` 是所有服務共用的基礎建設，錯誤日誌的格式在這裡決定一次，全體服務跟著生效。原本各處直接呼叫：

```go
slog.Error("should retry error", "error", eris.ToJSON(err, true))
```

`eris.ToJSON(err, true)` 回傳的是巢狀 `map[string]any`，裡面帶著堆疊框的陣列。這份結構經 OTLP 送到 Grafana Cloud 後，Loki 端會把巢狀結構**展平成每個堆疊框一個欄位**：

```
error_root_msg
error_root_stack_0
error_root_stack_1
error_root_stack_2
...
```

兩個問題：一是查詢時堆疊被拆散在數十個欄位裡，人眼難讀；二是 structured metadata 的欄位數與大小有上限，深的堆疊有觸頂風險。

同時，issue #1 剛讓每則日誌帶上 `code.file.path` / `code.function.name` / `code.line.number`。這裡有個陷阱：`slog` 的來源位置是在進入 `slog.Error` 等函式時，以**寫死的跳層數**呼叫 `runtime.Callers` 擷取的。一旦把日誌包進 helper，所有錯誤日誌的來源位置都會指向 helper 內部的那一行，等於讓 issue #1 對最需要它的錯誤日誌完全失效。

## 決策

**一、`core/logger` 提供單一錯誤日誌入口 `logger.Error(ctx, msg, err, args...)`。**

**二、堆疊以 OTEL 語意慣例的 `exception.stacktrace` 輸出成單一多行字串**，內容取自 `eris.ToString(err, true)`。單一字串欄位不會被 Loki 展平，且 `exception.stacktrace` 是 OTEL 標準屬性，Grafana 與其他 OTEL 工具都認得。

**二之一、外部錯誤用呼叫端的框補上堆疊。** `eris` 的堆疊只能在 `eris.New` / `eris.Wrap` 當下擷取，driver、net 等外部錯誤自身沒有堆疊，`eris.ToString` 對它們只會回傳 `"\n" + 訊息`（開頭還多一個換行）。而 `core` 這次改寫的呼叫點——`url.Error`、`tls.CertificateVerificationError`、`mysql.MySQLError`、goredis 錯誤、`Close()` 的關閉錯誤——**幾乎全是外部錯誤**，若原樣送出，`exception.stacktrace` 會只剩一行訊息，這條 AC 等於沒做到。

因此 `stacktrace()` 會先 `TrimSpace` 掉那個前導換行，再判斷 `eris.StackFrames(err)`：有框就直接用 eris 的輸出；沒框就用**入口自己已經擷取的 PC**（本來就要抓來修 caller，順道多抓幾層）補上呼叫端的框，格式沿用 eris 的 `func:file:line`。這樣補出來的堆疊從真正的呼叫端起算，不含 `logger.Error` 自己的框。

**三、入口內部自行擷取 caller PC 並組 `slog.Record`**，而非轉呼叫 `slog.ErrorContext`：

```go
const callerSkip = 2 // 0=runtime.Callers、1=Error 自己、2=真正的呼叫端

var pcs [1]uintptr
runtime.Callers(callerSkip, pcs[:])
record := slog.NewRecord(time.Now(), slog.LevelError, msg, pcs[0])
```

這是 Go `log/slog` 官方文件對「包裝 slog」給的作法。跳層數由測試 `TestErrorReportsCallerLineNotHelperInternals` 把關 —— 該測試斷言行號等於呼叫端的行號，所以未來若在入口與呼叫端之間再加一層，測試會直接失敗。

**四、入口收 `context`**，讓 OTEL 能把日誌與當下的 trace/span 關聯起來；原本的 `slog.Error` 不吃 ctx，錯誤日誌因此無法對應到 trace。`core` 內部為此把 `permanentIfNeeded` 與 `DataSourceName.buildDB` 的簽章補上 `ctx`。`ConnectionManager.Close()` 沒有可用的請求 context（關閉時 signal context 通常已 canceled），改用 `context.Background()`。

## 被否決的替代方案

**保留 `eris.ToJSON`，改在 Loki 端調整解析。** 否決：問題根源在送出端的資料形狀，在查詢端補救等於每個查詢都要處理一次；而且 structured metadata 的上限風險不會消失。

**用 `eris.Wrap` 補外部錯誤的堆疊（而非用自己擷取的 PC）。** 否決：`eris.Wrap` 的跳層數是寫死的，從入口內部呼叫會把 `logger.Error` 自己的框塞進堆疊頂端；而且 `Wrap` 必須給一個訊息，等於要為此發明一個包裝訊息，或讓日誌訊息在 body 與堆疊裡各出現一次。用入口本來就要抓的 PC 沒有這兩個問題。

**外部錯誤就不補堆疊，只留訊息。** 否決：一度採用過，理由是「錯誤在哪裡被記錄」已由 issue #1 的 `code.*` 三個欄位涵蓋。但 code review 時實測發現 `core` 這次改寫的呼叫點 100% 是外部錯誤，等於整個 `exception.stacktrace` 欄位退化成單行訊息，「內容多行可讀」這條 AC 形同虛設；而 `code.*` 只能指出**最後記錄的那一行**，指不出是哪條重試路徑走到這裡。

**同時輸出 `exception.type` 與 `exception.message`。** 否決（暫時）：AC 只要求 `exception.stacktrace`，而 `eris.ToString` 的第一行本身就是錯誤訊息。等到真的需要用型別做聚合查詢時再加，屆時是純增量的改動。

**把 caller 修正做成自訂 `slog.Handler`，而非在入口處理。** 否決：`slog` 的 PC 是在 `Record` 建立時就固定的，handler 拿到 record 時已經來不及修正；要在 handler 端做只能重新走一次 `runtime.Callers` 並猜測跳層數，比在入口直接控制更脆弱。

**讓入口自己決定 `slog.Logger`（例如吃一個 logger 參數）。** 否決：呼叫端會被迫到處傳 logger。改用 `slog.Default()`，由 `Manager.SetLogger` 在啟動時設定一次；測試則透過暫時替換 `slog.Default()` 來驗證，也因此測到的是真實的呼叫路徑與跳層數。

## 後果

- `core` 的錯誤日誌在 Grafana 上變成一個可直接閱讀的多行欄位，`error_root_stack_*` 消失。
- **各服務尚未遷移**：`telegram`、`center`、`exchange_rate`、`bookkeeping`、`email` 內仍有直接呼叫 `slog.Error(..., "error", eris.ToJSON(err, true))` 的地方，那些日誌還是會被展平。本票的範圍是 `core`（issue #2 原文：「`core` 自身既有的錯誤日誌呼叫點在此票一併改用新入口」），各服務的遷移要另開票。
- 目前沒有 lint 或測試會擋住「再度直接呼叫 `slog.Error`」，只靠 `core/CLAUDE.md` 的文字約束。
- 錯誤日誌的 `code.line.number` 指向真正出錯的呼叫端，issue #1 的價值在錯誤情境下得以保留。
- 錯誤日誌帶上 trace 關聯。
- 新增的約束：`core` 內的錯誤日誌一律走 `logger.Error`，不再直接呼叫 `slog.Error`。非錯誤等級（`slog.Info` / `slog.Debug`）不受此 ADR 約束，維持原樣。
- **前提在 [issue #3](https://github.com/leo84927/monorepo/issues/3) 之後改變（本 ADR 的決策不變）**：本 ADR 推論「二之一」時的前提是「`core` 這次改寫的呼叫點幾乎全是外部錯誤」。issue #3 讓 `core/rabbitmq` 的錯誤自誕生起就用 `eris.New` / `eris.Wrap` 攜帶堆疊，因此對 rabbitmq 的錯誤而言，`stacktrace()` 走的是 eris 自己的堆疊，PC 補償退居備援；`mariadb` / `redis` 等尚未包裝的外部錯誤仍靠補償路徑。補償邏輯本身沒有被移除，也沒有被取代。
- `permanentIfNeeded` 與 `buildDB` 的簽章多了 `ctx`，屬 `core` 內部函式，不影響各服務。
