#!/usr/bin/env bash
# Installs lab tooling on Ubuntu (WSL2): kubectl, kind, helm, terraform.
# Docker is expected to be installed already.
set -euo pipefail

BIN=/usr/local/bin
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

sudo apt-get update -qq
sudo apt-get install -y -qq unzip jq make bash-completion curl

echo ">> kubectl"
KUBECTL_VER=$(curl -Ls https://dl.k8s.io/release/stable.txt)
curl -sLO "https://dl.k8s.io/release/${KUBECTL_VER}/bin/linux/amd64/kubectl"
sudo install kubectl "$BIN/"

echo ">> kind"
curl -sLo kind https://github.com/kubernetes-sigs/kind/releases/latest/download/kind-linux-amd64
sudo install kind "$BIN/"

echo ">> helm"
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo ">> terraform"
TF_VER=$(curl -s https://checkpoint-api.hashicorp.com/v1/check/terraform | jq -r .current_version)
curl -sLO "https://releases.hashicorp.com/terraform/${TF_VER}/terraform_${TF_VER}_linux_amd64.zip"
unzip -q "terraform_${TF_VER}_linux_amd64.zip" terraform
sudo install terraform "$BIN/"

# kubectl completion + alias k (only once)
if ! grep -q 'alias k=kubectl' ~/.bashrc; then
  echo 'source <(kubectl completion bash); alias k=kubectl; complete -o default -F __start_kubectl k' >> ~/.bashrc
fi

echo
kubectl version --client
kind version
helm version --short
terraform version | head -1
