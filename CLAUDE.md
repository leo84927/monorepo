# mono repository
個人 side-project，以多個微服務構成  
為了讓 AI 更容易看清整個架構，用 monorepo 的方式管理

```sh
# 初次 clone，一行完整執行
git clone --recurse-submodules <remote_url>
# 分段執行，與前者等價
git clone <remote_url>
git submodule init
git submodule update
# git submodule init + git submodule update
git submodule update --init --recursive

# 一次 pull 所有 submodule
git submodule update --remote --merge

# 初始化 go.work
go work init
# 添加所有有 go.mod 的 service
go work use ./<service_name>
```

## 版本命名規範
一律採三碼命名規則，例如：v1.2.3

## scheduler
Protocol Buffers 文件倉，除了透過 github 做版本控制  
也有使用 Buf Schema Registry（BSR）管理 label，提供給各個服務 go get  
細節參考 ./scheduler/CLAUDE.md

## docker
內含各個服務與基礎設施的 docker-compose 設定  
細節參考 ./docker/CLAUDE.md

## core
封裝服務之間共用的基礎建設使用方法，或是重複性極高，每個服務都必須要寫一遍的代碼  
細節參考 ./core/CLAUDE.md

## center
定時任務的發起者，發送任務至 rabbitmq 後，由各個微服務自行消費  
細節參考 ./center/CLAUDE.md

## exchange_rate
接收 center 的任務，定期發送匯率到 telegram，貨幣組合由 center 指定  
細節參考 ./exchange_rate/CLAUDE.md

## telegram
負責處理所有與 telegram bot 相關的任務，比如 send message、webhook ......
細節參考 ./telegram/CLAUDE.md

## email
接收 center 的任務，定期清理個人郵件或針對郵件做特別處理

## bookkeeping
記帳服務，目前只有該服務可以存取資料庫  
資料來源為:
1. 使用者透過 telegram bot 輸入
2. email 服務對消費紀錄信件做的特殊處理
