---
paths:
  - "deploy.sh"
  - "./core/logger/*.go"
---

# 生產環境部署

- **VM**: GCE e2-micro（Debian），us-west1-b
- **執行方式**: 直接跑 Go binary（不用 Docker），由 systemd 管理
- **設定檔位置**: `/etc/monorepo/<service>.env`（systemd EnvironmentFile）
- **Unit file 位置**: `/etc/systemd/system/<service>.service`
- **Binary 位置**: `/home/leo/monorepo/`
- **已知限制**: VM 在美國區域，Binance API 會擋美國 IP

## 部署流程

```sh
# 1. 本機交叉編譯（-trimpath 必帶，見下方「日誌來源路徑」）
GOOS=linux GOARCH=amd64 go build -trimpath -o <service_name> <path>

# 2. 上傳
gcloud compute scp <binary_file> monorepo-server:/home/leo/monorepo/ --zone=us-west1-b

# 3. VM 上重啟
sudo systemctl restart <service>
```

完整部署指令參考 deploy.sh

## 日誌來源路徑（-trimpath 必帶）

日誌的其中一個參數 `code.file.path` 取自 binary 內記錄的編譯期路徑，**不帶 `-trimpath` 就會是建置機的絕對路徑**
（例如 `/Users/leo/go/src/monorepo/telegram/handle/webhook.go`）。  
帶上 `-trimpath` 後會裁成相對路徑：`telegram/handle/webhook.go`，core 為
`github.com/leo84927/core/logger/log.go`。

因此**所有**建置管道都必須帶 `-trimpath`，目前共四處：本檔上方的部署流程、本檔下方「常用指令」的 build、`deploy.sh`、`docker/application.yml`。  
新增建置管道時要一併帶上，否則同一份程式碼會因為用哪個指令建置而產生不同的日誌路徑。
