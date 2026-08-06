# mono repository
個人 side-project，以多個微服務構成  
為了讓 AI 更容易看清整個架構，用 monorepo 的方式管理

架構全貌、跨服務語彙與訊息流向見根目錄 `CONTEXT.md`。

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
| Upstash Redis | 環境變數儲存（取代 Consul） | key pattern 見 `CONTEXT.md` 的 Service prefix |
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

# 僅允許 telegram IP
gcloud compute firewall-rules update allow-telegram-webhook \
  --source-ranges=149.154.160.0/20,91.108.4.0/22

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
| bookkeeping | （尚無） |

## Agent skills

### Issue tracker

Issue 與 PRD 存在 GitHub Issues（`leo84927/monorepo`），透過 `gh` CLI 操作。詳見 `docs/agents/issue-tracker.md`。

### Triage labels

沿用五個標準 triage 角色標籤，標籤字串等同角色名稱。詳見 `docs/agents/triage-labels.md`。

### Domain docs

Single-context：根目錄 `CONTEXT.md` + `docs/adr/`。詳見 `docs/agents/domain.md`。
