#!/usr/bin/env bash
set -euo pipefail

echo "==> Bootstrap Ubuntu Dev Environment"

if ! command -v sudo >/dev/null 2>&1; then
  echo "ERRO: sudo não encontrado. Rode como root ou instale sudo."
  exit 1
fi

echo "==> Atualizando APT..."
sudo apt update

echo "==> Instalando dependências base..."
sudo apt install -y \
  ca-certificates \
  curl \
  wget \
  gpg \
  gnupg \
  unzip \
  apt-transport-https \
  software-properties-common \
  lsb-release \
  jq \
  git

echo "==> Criando diretórios de keyrings..."
sudo install -d -m 0755 /etc/apt/keyrings
sudo install -d -m 0755 /usr/share/keyrings

echo "==> Configurando repositório do GitHub CLI..."
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null

sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null

echo "==> Configurando repositório do VS Code..."
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
  | gpg --dearmor \
  | sudo tee /usr/share/keyrings/microsoft.gpg >/dev/null

sudo chmod a+r /usr/share/keyrings/microsoft.gpg

sudo tee /etc/apt/sources.list.d/vscode.sources >/dev/null <<'VSCODE_REPO'
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64,arm64,armhf
Signed-By: /usr/share/keyrings/microsoft.gpg
VSCODE_REPO

echo "==> Atualizando APT após adicionar repositórios..."
sudo apt update

echo "==> Instalando Git, GitHub CLI e VS Code..."
sudo apt install -y git gh code

echo "==> Instalando Google Chrome..."
ARCH="$(dpkg --print-architecture)"

if [ "$ARCH" = "amd64" ]; then
  CHROME_DEB="/tmp/google-chrome-stable_current_amd64.deb"

  wget -O "$CHROME_DEB" \
    https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb

  sudo apt install -y "$CHROME_DEB"
  rm -f "$CHROME_DEB"
else
  echo "AVISO: Google Chrome oficial via .deb estável normalmente é para amd64."
  echo "Arquitetura atual: $ARCH"
  echo "Instalando Chromium como fallback..."
  sudo apt install -y chromium-browser || sudo apt install -y chromium
fi

echo "==> Instalando ou atualizando AWS CLI v2..."
TMP_DIR="$(mktemp -d)"
cd "$TMP_DIR"

MACHINE="$(uname -m)"

case "$MACHINE" in
  x86_64)
    AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
    ;;
  aarch64|arm64)
    AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
    ;;
  *)
    echo "ERRO: arquitetura não suportada automaticamente pela AWS CLI: $MACHINE"
    exit 1
    ;;
esac

curl -fsSL "$AWS_CLI_URL" -o awscliv2.zip
unzip -q awscliv2.zip

if command -v aws >/dev/null 2>&1; then
  sudo ./aws/install \
    --bin-dir /usr/local/bin \
    --install-dir /usr/local/aws-cli \
    --update
else
  sudo ./aws/install \
    --bin-dir /usr/local/bin \
    --install-dir /usr/local/aws-cli
fi

cd ~
rm -rf "$TMP_DIR"

echo "==> Garantindo atualizações finais..."
sudo apt update
sudo apt upgrade -y

echo
echo "==> Versões instaladas:"
echo "Git:"
git --version || true

echo
echo "GitHub CLI:"
gh --version || true

echo
echo "AWS CLI:"
aws --version || true

echo
echo "VS Code:"
code --version || true

echo
echo "Google Chrome:"
google-chrome --version || chromium-browser --version || chromium --version || true

echo
echo "==> Instalação concluída."
echo
echo "Próximos comandos úteis:"
echo "  gh auth login"
echo "  aws configure"
echo
echo "Configuração opcional do Git:"
echo "  git config --global user.name \"Seu Nome\""
echo "  git config --global user.email \"seu-email@exemplo.com\""
