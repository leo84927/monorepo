---
paths:
  - "./core/logger/*.go"
---

`core/logger` 讓所有服務的每則日誌都帶上 `code.file.path`、`code.function.name`、`code.line.number`
（機制見 `core/CLAUDE.md` 的「Logger caller 來源位置」）。
