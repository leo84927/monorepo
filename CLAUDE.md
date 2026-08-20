# mono repository
架構全貌、跨服務語彙與訊息流向見根目錄 `CONTEXT.md`。

## 版本命名規範
三碼命名規則，例：v1.2.3

## 基礎設施（外部服務）

| 服務 | 用途 | 備註 |
|------|------|------|
| CloudAMQP | RabbitMQ 託管 | 訊息佇列 |
| Upstash Redis | 環境變數儲存 | key pattern 見 `CONTEXT.md` 的 Service prefix |
| Grafana Cloud | Log + Trace（OTLP HTTP） | endpoint + auth header 存在 Redis |

## 各服務入口

服務職責與相互關係見 `CONTEXT.md`；以下只列各服務的細節文件位置。

| 服務 | 細節文件 |
|---|---|
| scheduler | `./scheduler/CLAUDE.md` |
| docker | `./docker/CLAUDE.md` |
| core | `./core/CLAUDE.md` |
| center | `./center/CLAUDE.md` |
| exchange_rate | `./exchange_rate/CLAUDE.md` |
| telegram | `./telegram/CLAUDE.md` |
| email | （尚無） |
| bookkeeping | `./bookkeeping/CLAUDE.md` |

## 各服務的通用 CI
```sh
# 測試（-race、-v、-count=1 每次測試必加）
go test ......... -race -v -count=1

# Lint（CI 用 golangci-lint，只掃變更套件）
golangci-lint run <路徑>
```

## Agent skills

### Issue tracker

Issue 與 PRD 存在 GitHub Issues（`leo84927/monorepo`），透過 `gh` CLI 操作。詳見 `docs/agents/issue-tracker.md`。

### Triage labels

沿用五個標準 triage 角色標籤，標籤字串等同角色名稱。詳見 `docs/agents/triage-labels.md`。

### Domain docs

Single-context：根目錄 `CONTEXT.md` + `docs/adr/`。詳見 `docs/agents/domain.md`。
