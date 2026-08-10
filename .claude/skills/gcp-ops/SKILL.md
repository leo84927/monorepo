---
name: gcp-ops
description: GCE VM 建立、防火牆、systemd 服務管理的 gcloud/systemctl 指令參考
disable-model-invocation: true
---

# GCP 維運指令

建置、上傳、重啟這條部署流程見 `.claude/rules/deployment.md`；本檔只收 VM／網路／systemd 的維運指令。

## VM 本身

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
```

## 靜態 IP / 防火牆

```sh
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
```

## systemd

```sh
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
