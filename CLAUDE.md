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

## 基礎設施（外部服務）

| 服務 | 用途 | 備註 |
|------|------|------|
| CloudAMQP | RabbitMQ 託管 | 訊息佇列 |
| Upstash Redis | 環境變數儲存（取代 Consul） | `GLOBAL:*` + `<PREFIX>:*` key pattern |
| Grafana Cloud | Log + Trace（OTLP HTTP） | endpoint + auth header 存在 Redis |

## 生產環境部署

- **VM**: GCE e2-micro（Debian），us-west1-b
- **執行方式**: 直接跑 Go binary（不用 Docker），由 systemd 管理
- **設定檔位置**: `/etc/monorepo/<service>.env`（systemd EnvironmentFile）
- **Unit file 位置**: `/etc/systemd/system/<service>.service`
- **Binary 位置**: `/home/leo/monorepo/`
- **已知限制**: VM 在美國區域，Binance API 會擋美國 IP

### 部署流程

```sh
# 1. 本機交叉編譯
GOOS=linux GOARCH=amd64 go build -o <service_name> <path>

# 2. 上傳
gcloud compute scp <binary_file> monorepo-server:/home/leo/monorepo/ --zone=us-west1-b

# 3. VM 上重啟
sudo systemctl restart <service>
```

完整部署指令參考 deploy.sh

### 常用指令

```sh
# 建立 VM，以下為不同 OS
gcloud compute instances create monorepo-server \
  --machine-type=e2-micro \
  --zone=us-west1-b \
  --image-family=debian-12 \
  --image-project=debian-cloud

gcloud compute instances create monorepo-server \
  --machine-type=e2-micro \
  --zone=us-west1-b \
  --image-family=cos-stable \
  --image-project=cos-cloud

# 確認 instance 名稱和 zone
gcloud compute instances list
# 刪除
gcloud compute instances delete monorepo-server --zone=us-west1-b

# ssh
gcloud compute ssh monorepo-server --zone=us-west1-b
# build
GOOS=linux GOARCH=amd64 go build -o <service_name> <path>
# scp
gcloud compute scp <binary_file> monorepo-server:/home/leo/monorepo/ --zone=us-west1-b

# 建立靜態 ip
gcloud compute addresses create monorepo-ip --region=us-west1
# 解除 VM 對外的網路
gcloud compute instances delete-access-config monorepo-server \
  --zone=us-west1-b \
  --access-config-name="external-nat"
# 查詢
gcloud compute addresses describe monorepo-ip --region=us-west1
# 綁定靜態 ip
gcloud compute instances add-access-config monorepo-server \
  --zone=us-west1-b \
  --address=34.168.28.200
# 列出所有靜態 ip
gcloud compute addresses list
# 設定防火牆
gcloud compute firewall-rules create allow-telegram-webhook
  --direction=INGRESS \        # 入站流量
  --action=ALLOW \             # 允許
  --rules=tcp:8443 \           # 對象：TCP port 8443
  --source-ranges=0.0.0.0/0 \  # 來源：任何 IP
  --target-tags=telegram-webhook  # 只套用到有這個 tag 的 VM
# 讓設定生效
gcloud compute instances add-tags monorepo-server
  --zone=us-west1-b \
  --tags=telegram-webhook

# systemd 的 .service 位置
ls /etc/systemd/system/
# 載入新的 .service
sudo systemctl daemon-reload
# 設置為開機啟動
sudo systemctl enable --now <service_name>
# systemctl 相關指令
systemctl status <service_name>
sudo systemctl start <service_name>
sudo systemctl stop <service_name>
sudo systemctl restart <service_name>
```

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
