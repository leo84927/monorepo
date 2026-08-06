# Domain 文件

說明各 engineering skill 在探索本 codebase 時，應該如何使用本專案的 domain 文件。

**佈局：single-context。** monorepo 根目錄放一份 `CONTEXT.md` 與一個 `docs/adr/`，涵蓋整個系統。所有檔案都留在 `leo84927/monorepo` 這個 repo，不會寫入任何服務 submodule。

## 探索前先讀這些

- 根目錄的 **`CONTEXT.md`**
- **`docs/adr/`** —— 閱讀與即將動工區域相關的 ADR。

若這些檔案不存在，**靜默繼續即可**。不要提示它們缺少，也不要主動建議先建立。`/domain-modeling`（可經由 `/grill-with-docs` 與 `/improve-codebase-architecture` 觸發）會在真正需要釐清術語或記錄決策時才 lazily 建立。

各服務自己的 `CLAUDE.md`（`center/CLAUDE.md`、`core/CLAUDE.md` 等）已經記載了該服務的內部機制，請與 `CONTEXT.md` 一併閱讀。但它們不能取代 glossary：共用的 domain 詞彙一律以 `CONTEXT.md` 為準。

## 檔案結構

```
/
├── CONTEXT.md
├── docs/
│   ├── adr/
│   │   ├── 0001-....md
│   │   └── 0002-....md
│   └── agents/
├── center/          ← submodule，有自己的 CLAUDE.md
├── core/            ← submodule，有自己的 CLAUDE.md
└── ...
```

## 使用 glossary 的詞彙

當輸出內容提到某個 domain 概念時（issue 標題、重構提案、假設、測試名稱等），一律採用 `CONTEXT.md` 中的定義用詞，不要漂移成 glossary 明確避免使用的同義詞。

如果需要的概念還不在 glossary 裡，這本身就是訊號 —— 要嘛是你在發明專案並不使用的語彙（請重新考慮），要嘛是真的有缺口（記下來交給 `/domain-modeling`）。

## 明確指出與 ADR 的衝突

如果輸出內容與既有 ADR 相矛盾，必須明確指出，不可默默覆蓋既有決策：

> _與 ADR-0007（event-sourced orders）相衝突 —— 但值得重新討論，因為……_
