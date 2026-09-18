# ADR-0004：`core` 升 `/v2` 與 `email` 的版本分岔

- **狀態**：已採用
- **日期**：2026-09-18
- **相關**：[issue #29](https://github.com/leo84927/monorepo/issues/29)、[issue #28](https://github.com/leo84927/monorepo/issues/28)（模組路徑與 tag）、[issue #16](https://github.com/leo84927/monorepo/issues/16)（交付切法）、[issue #15](https://github.com/leo84927/monorepo/issues/15)（版本策略）、[issue #12](https://github.com/leo84927/monorepo/issues/12)（email 移出納管）、[issue #7](https://github.com/leo84927/monorepo/issues/7)（架構深化修正計劃）

## 脈絡

ADR-0002 與 ADR-0003 這批改動在 `core` 留下三處編譯期破壞：`MsgHandler` 收斂為只回 `error`、`config` 的九個套件層變數與七個匯出函式換成 `Load(ctx, Spec) (Settings, error)`、`initialize.New` 改吃位置參數 `New(ctx, settings, app)`。四個服務（`center`、`exchange_rate`、`telegram`、`bookkeeping`）全部編不過。

`core/go.mod:1` 原本是 `module github.com/leo84927/core`，沒有版本後綴。Go 的規則使 v2 以上必須把模組路徑改成 `github.com/leo84927/core/v2`，否則 `go get @v2.0.0` 直接被拒。所以只有兩條真路：改 `/v2`（正確 semver，代價是四個服務的 import 與 `go.mod` 機械替換），或打 `v1.8.0`（把 breaking 塞進 minor，零 churn 但在 public module 上說謊）。

有兩個事實改變了這個選擇的重量：

**一、`email` 已移出納管（#12）。** 它釘在 `core v1.4.1`、呼叫早已不存在的 `InitFromConsul("EMAIL")`，而 `center` 的 email cron 全數註解、`GetEmailScheduler()` 回空 slice —— 依 #12／#15 的查證記錄，它既啟動不了、也沒有工作可做。

**二、monorepo 根目錄有一個 gitignore 的 `go.work`，把五個模組全部納進 workspace。** 四個服務的 `go.mod` 雖然寫著 `require github.com/leo84927/core …`，本機編譯完全不理那一行、一律吃 `./core`；而 `deploy.sh:12` 是在 monorepo 根目錄跑 `go build ./<service>`，`GOWORK` 就在那裡生效。**上機器的 binary 從來不是 tag 建出來的，而是本機工作目錄的 core。**

## 決策

### 一、模組路徑改 `/v2`，理由是版本分岔而非 semver 教條

這批每一項行為改變都綁著一個編譯期破壞（設定 fallback 改報錯綁著 `Load` 取代 `InitFromRedis`，ack 時機綁著 `MsgHandler` 簽名收斂），所以誤升的人拿到的是 compile error 而不是一個行為悄悄改變的執行檔 —— `v1.8.0` 的實際風險趨近於零。選 `/v2` 的真正理由是 `email`：**`/v2` 讓「`email` 的 v1 與四個服務的 v2 是兩個世界」永久寫在版本字串裡**，代價只有一次 sed。日後沒有人會再讀這張地圖去搞懂 email 為什麼壞。

### 二、`/v2` 排在整批改動的最後

改模組路徑會讓 `go.work` 不再滿足四個服務的 `require`，解析**無聲退回 module cache**。所以必須等四個服務都遷移完才動：此時 sed 之前的中間狀態是「新程式碼配 module cache 裡的 v1.7.8」的編譯錯誤，大聲且指向明確；無聲退回只會發生在「服務端還是舊碼」的順序下，本決策的排序排除了它。

### 三、v1 線凍結在 `v1.7.8`，不開維護分支

git tag 不可變、Go proxy 有快取，只要不刪 tag、不改寫歷史，`email` 永遠拿得到 `v1.4.1`。`core` 對 `email` 零相容保證。這不是「代價可接受」，而是約束根本不存在。

### 四、打 tag 與改模組路徑之後**不重新部署**

`go.work` 之下，sed 前後編出的 binary 完全相同，tag 也不改變任何已部署行為。因此這一階段的完成定義只有「五個 repo `go build ./...` 全過」，不含部署。

## 被否決的替代方案

**打 `v1.8.0`，把 breaking 塞進 minor。** 否決：零 churn，但版本字串會說「這是相容的」。而且它拿不到本 ADR 真正想買的東西 —— email 與四服務的分岔在版本號上看不出來。

**先打一個只含部分子項的 tag，讓服務早點開工。** 否決：tag 一打出去四個服務就會指過來，這時才發現 ack 契約有洞，代價是四次重新 bump。分批部署本來就不需要服務同時開工。

**`/v2` 排在 `core` 改動的最前面（原 #15 的 A5）。** 否決：見決策二。模組路徑一改，`go.work` 的解析就退回 module cache，而退回是無聲的 —— 整批改動會在一個「看起來編得過但吃的是舊 core」的狀態下進行。

**為 `email` 開 v1 維護分支。** 否決：見決策三。它要維護的對象既啟動不了也沒有工作可做。

**等 `email` 一起遷移，維持單一版本線。** 否決：`email` 的遷移是一個獨立且無人受益的工程（它連 consul 都還在用），把它綁進本批只會讓本批無法結束。

## 後果

- 模組路徑為 `github.com/leo84927/core/v2`，四個服務的 `go.mod` 皆 `require github.com/leo84927/core/v2 v2.0.2`。
- **實際 tag 與 #28 的驗收條件（單一 tag `v2.0.0`）不符：v2 線上有三個 tag，而只有 `v2.0.2` 可用。** `v2.0.0`（`e1da364`）與 `v2.0.1`（`edc688b`）都打在 `go.mod` 仍宣告 v1 路徑的 commit 上，實測：

  ```
  $ go list -m github.com/leo84927/core/v2@v2.0.0
  go: github.com/leo84927/core/v2@v2.0.0: invalid version: go.mod has non-.../v2
  module path "github.com/leo84927/core" (and .../v2/go.mod does not exist) at revision v2.0.0
  ```

  `v2.0.2`（`3169a41`）是改完模組路徑的那個 commit，解析正常。**教訓：`/v2` 的第一個 tag 必須打在模組路徑改完之後的 commit 上，否則那個 tag 從誕生起就不可解析。** 版本分岔本身不受影響 —— 有效版本是 `v2.0.2`，四個服務都指向它。
- `v1.7.8` 是 v1 線的最後一個版本。`email` 與 `core` 之後各走各的。
- 已部署的行為不變。tag 與部署解耦是 `go.work` 的後果，不是這次的決定 —— 但它也意味著**「上機器的是哪一版 core」無法從 tag 反推**，只能從 monorepo 的 submodule 指標反推。這是本批刻意把「四個服務必然跑同一份 core commit」寫進交付順序（#16 的「core 在 C 階段凍結」）的原因。
- **與 ADR-0003 的一項後果相衝突，在此明確指出：** ADR-0003 的後果段寫「`CONTEXT.md` 不需要改動：`Spec` / `Settings` 是 `core` 的實作型別，不是跨服務語彙」。本批仍然改了 `CONTEXT.md` 的 **Topology** 條目，並在其中引用 `Spec.Queue`。理由是該條目原本點名了 `LoadBasicTopology` / `LoadCompleteTopology` 兩個**已被刪除**的函式 —— 不改就是留一條指向不存在符號的定義。`Spec` 出現在那裡是為了說明「producer 與 consumer 的差別宣告在哪裡」，不是把它升格為跨服務語彙；ADR-0003 關於 `Settings` 與「設定鍵」／「Service prefix」兩則定義不必動的判斷仍然成立。
- `CONTEXT.md` 服務職責表的 `core` 一列同步改為 `go get github.com/leo84927/core/v2`。這超出 #29 所列的「`CONTEXT.md` 唯一必改的一處」，但那句話寫於 `/v2` 落地之前，留著舊字串等於在 glossary 裡放一條本批親手弄假的事實。
- `docs/adr/` 的三篇 ADR（0002、0003、0004）與 monorepo 的 submodule 指標一起構成這批改動的可重現全景；中途每一個指標組合都是半遷移狀態，因此 submodule 只 bump 一次。
