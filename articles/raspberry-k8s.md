# Raspberry Pi + Ubuntu 24.04 で作る Kubernetes クラスター構築ガイド

このドキュメントでは、複数の Raspberry Pi に Ubuntu 24.04 をインストールし、kubeadm を使用して Kubernetes (k8s) クラスターを構築する手順をまとめています。
## 1. 基本用語の解説用語役割
kubeadmクラスターの構築・管理（初期化やノード参加）を行うツール。kubelet各ノードで動作する「現場監督」。コンテナの実行状態を管理する。kubectl管理者がクラスターに命令を出すためのコマンドラインツール。containerd実際にコンテナを動かすエンジン（ランタイム）。CNI (Flannel)Pod（コンテナ）同士が通信するための仮想ネットワーク。

## 2. 全ノード共通の下準備
※ 親機（Control Plane）と子機（Worker Node）のすべてで実行します。

### 2.1 OS 設定の変更

```sh
# スワップの無効化（k8sでは必須）
sudo swapoff -a
sudo sed -i '/swap/s/^/#/' /etc/fstab
# カーネルモジュールのロード設定
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
# ネットワークブリッジの設定
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

### 2.2 コンテナランタイム (containerd) の導入sudo apt update

```sh
sudo apt install -y containerd conntrack
# デフォルト設定の書き出しと修正（SystemdCgroupを有効化）
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

sudo systemctl restart containerd
```

### 2.3 Kubernetes ツール群のインストール

```sh
sudo apt update && sudo apt install -y apt-transport-https ca-certificates curl gpg
# 公開鍵とリポジトリの追加
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
# インストール
sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

## 3. コントロールプレーンの設定※ 1台目の親機のみで実行します。
### 3.1 クラスターの初期化

```sh
sudo kubeadm init --pod-network-cidr=10.244.0.0/16
```
### 3.2 ネットワーク (CNI: Flannel) の導入

```sh
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

## 4. ワーカーノードの追加※ 子機で実行します。必ず sudo を付けてください。

```sh
sudo kubeadm join <親機のIP>:6443 --token <トークン> --discovery-token-ca-cert-hash sha256:<ハッシュ>
```

## 5. LoadBalancer の導入 (MetalLB)
※ 親機（tomo-main）のみで 1 回実行します。
### 5.1 ARP 設定の変更 (kube-proxy)
```sh
kubectl edit configmap -n kube-system kube-proxy
```
strictARP: false を true に変更して保存

### 5.2 MetalLB のインストール
```sh
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml
```

### 5.3 インストール完了の確認
```sh
kubectl get pods -n metallb-system
kubectl get crd | grep metallb
```

### 5.4 IP アドレスプールの設定
metallb-config.yaml を以下の内容（apiVersion修正版）で作成し、適用します。

```yml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: first-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.0.200-192.168.0.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-adv
  namespace: metallb-system
spec:
  ipAddressPools:
  - first-pool
```

```sh
kubectl apply -f metallb-config.yaml
```

## 6. 動作確認kubectl get svc nginx-service
EXTERNAL-IP が割り当てられれば成功です。
