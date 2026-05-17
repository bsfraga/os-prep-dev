#!/usr/bin/env bash
# =============================================================================
# bootstrap-dev-env-live.sh
# Bootstrap idempotente para Ubuntu Live Persistence
# Seguro para rodar múltiplas vezes — não reinstala o que já está instalado
# =============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
# Utilitários
# -----------------------------------------------------------------------------

log() {
  echo
  echo "========================================"
  echo "==> $1"
  echo "========================================"
}

ok() {
  echo "    [OK] $1"
}

skip() {
  echo "    [--] $1 (já configurado, pulando)"
}

is_live_session() {
  grep -qE 'boot=casper|maybe-ubiquity' /proc/cmdline 2>/dev/null && return 0
  findmnt -n -o FSTYPE / 2>/dev/null | grep -q '^overlay$' && return 0
  mount | grep -qiE 'overlay|casper|cow|/cdrom' && return 0
  return 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

package_installed() {
  dpkg -s "$1" >/dev/null 2>&1
}

file_contains() {
  grep -qF "$2" "$1" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Pré-requisito: sudo
# -----------------------------------------------------------------------------

require_sudo() {
  if ! command_exists sudo; then
    echo "ERRO: sudo não encontrado. Rode como root ou instale sudo."
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# Diagnóstico do ambiente
# -----------------------------------------------------------------------------

show_environment() {
  log "Ambiente detectado"
  echo "Hostname        : $(hostname)"
  echo "Kernel          : $(uname -r)"
  echo "Arquitetura CPU : $(uname -m)"
  echo "Arquitetura APT : $(dpkg --print-architecture)"
  echo "Root filesystem : $(findmnt -n -o FSTYPE / || true)"
  if is_live_session; then
    echo "Modo            : Live/Persistence"
  else
    echo "Modo            : Instalação normal"
  fi
  echo
  df -h /
}

# -----------------------------------------------------------------------------
# Proteções Live Persistence (idempotente)
# -----------------------------------------------------------------------------

apply_live_persistence_safety() {
  if ! is_live_session; then
    log "Instalação normal detectada; proteções de Live Persistence não aplicadas"
    return 0
  fi

  log "Aplicando proteções para Live Persistence"

  # Desativar kdump-tools
  sudo systemctl disable --now kdump-tools 2>/dev/null || true

  if package_installed kdump-tools; then
    sudo dpkg --remove --force-remove-reinstreq kdump-tools 2>/dev/null || true
    sudo apt-get purge -y kdump-tools 2>/dev/null || true
    ok "kdump-tools removido"
  else
    skip "kdump-tools (não instalado)"
  fi

  sudo rm -f /etc/kernel/postinst.d/kdump-tools
  sudo rm -f /etc/kernel/postrm.d/kdump-tools

  # Pin para bloquear upgrades de kernel (idempotente via tee)
  sudo tee /etc/apt/preferences.d/99-live-no-kernel-upgrades >/dev/null <<'PIN_KERNEL'
Package: linux-generic* linux-image* linux-modules* linux-headers* linux-tools* linux-main-modules* kdump-tools
Pin: release *
Pin-Priority: -1
PIN_KERNEL
  ok "Pin de kernel gravado"

  # Marcar pacotes de kernel como hold
  INSTALLED_KERNEL_PACKAGES="$(
    dpkg-query -W -f='${binary:Package}\n' \
      'linux-generic*' \
      'linux-image*' \
      'linux-modules*' \
      'linux-headers*' \
      'linux-tools*' \
      'linux-main-modules*' \
      2>/dev/null | sort -u || true
  )"

  if [ -n "$INSTALLED_KERNEL_PACKAGES" ]; then
    echo "$INSTALLED_KERNEL_PACKAGES" | xargs -r sudo apt-mark hold 2>/dev/null || true
    ok "Pacotes de kernel marcados como hold"
  fi
}

# -----------------------------------------------------------------------------
# Reparo de estado dpkg (idempotente)
# -----------------------------------------------------------------------------

repair_dpkg_state() {
  log "Verificando e reparando estado do dpkg/APT"

  apply_live_persistence_safety

  sudo dpkg --configure -a || true
  sudo apt-get -f install -y || true

  if sudo dpkg --audit 2>/dev/null | grep -q .; then
    echo "AVISO: dpkg ainda encontrou pacotes pendentes. Tentando segunda correção..."
    apply_live_persistence_safety
    sudo dpkg --configure -a || true
    sudo apt-get -f install -y || true
  else
    ok "dpkg sem pacotes quebrados"
  fi
}

# -----------------------------------------------------------------------------
# Otimizações de performance para Live Persistence (idempotente)
# -----------------------------------------------------------------------------

apply_performance_tweaks() {
  log "Aplicando otimizações de performance para Live Persistence"

  # --- zRAM ---
  if package_installed zram-tools; then
    skip "zram-tools"
  else
    sudo apt-get install -y zram-tools
    ok "zram-tools instalado"
  fi

  ZRAM_CONF="/etc/default/zramswap"
  if file_contains "$ZRAM_CONF" "ALGO=zstd"; then
    skip "configuração do zRAM"
  else
    sudo sed -i 's/^#*\s*ALGO=.*/ALGO=zstd/' "$ZRAM_CONF"
    sudo sed -i 's/^#*\s*PERCENT=.*/PERCENT=50/' "$ZRAM_CONF"
    grep -q '^ALGO=' "$ZRAM_CONF" || echo 'ALGO=zstd' | sudo tee -a "$ZRAM_CONF" >/dev/null
    grep -q '^PERCENT=' "$ZRAM_CONF" || echo 'PERCENT=50' | sudo tee -a "$ZRAM_CONF" >/dev/null
    sudo systemctl restart zramswap 2>/dev/null || true
    ok "zRAM configurado (50% da RAM, compressor zstd)"
  fi

  # --- swappiness ---
  SYSCTL_CONF="/etc/sysctl.d/99-live-performance.conf"
  if [ -f "$SYSCTL_CONF" ]; then
    skip "sysctl de performance (swappiness/cache_pressure)"
  else
    sudo tee "$SYSCTL_CONF" >/dev/null <<'SYSCTL'
# Otimizações para Live Persistence em pendrive
vm.swappiness=10
vm.vfs_cache_pressure=50
SYSCTL
    sudo sysctl --system >/dev/null 2>&1 || true
    ok "swappiness=10 e vfs_cache_pressure=50 aplicados"
  fi

  # --- noatime no mount do overlay/persistence ---
  # Em Live Persistence o / é overlay; não editamos fstab diretamente,
  # mas podemos remountar com noatime na sessão atual.
  if mount | grep -q 'on / .*noatime'; then
    skip "noatime no / (já ativo)"
  else
    sudo mount -o remount,noatime / 2>/dev/null && ok "noatime aplicado no /" || true
  fi

  echo
  echo "  Resumo de memória e swap:"
  free -h
}

# -----------------------------------------------------------------------------
# Pacotes base (idempotente via apt install -y — safe se já instalado)
# -----------------------------------------------------------------------------

install_base_packages() {
  log "Instalando pacotes base"

  sudo apt-get install -y \
    apt-transport-https \
    build-essential \
    ca-certificates \
    curl \
    file \
    gpg \
    gnupg \
    jq \
    lsb-release \
    openssh-client \
    software-properties-common \
    unzip \
    wget \
    xclip \
    zip \
    git \
    git-lfs

  ok "Pacotes base prontos"
}

# -----------------------------------------------------------------------------
# Upgrade seguro (idempotente — apt upgrade já é safe)
# -----------------------------------------------------------------------------

safe_system_upgrade() {
  log "Executando apt upgrade seguro (sem kernel)"

  apply_live_persistence_safety
  sudo apt-get update -q
  sudo apt-get upgrade -y
  ok "Sistema atualizado"
}

# -----------------------------------------------------------------------------
# Repositório GitHub CLI (idempotente)
# -----------------------------------------------------------------------------

setup_github_cli_repo() {
  local KEY="/etc/apt/keyrings/githubcli-archive-keyring.gpg"
  local LIST="/etc/apt/sources.list.d/github-cli.list"

  if [ -f "$KEY" ] && [ -f "$LIST" ]; then
    skip "repositório do GitHub CLI"
    return 0
  fi

  log "Configurando repositório oficial do GitHub CLI"

  sudo install -d -m 0755 /etc/apt/keyrings

  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee "$KEY" >/dev/null
  sudo chmod go+r "$KEY"

  echo "deb [arch=$(dpkg --print-architecture) signed-by=${KEY}] https://cli.github.com/packages stable main" \
    | sudo tee "$LIST" >/dev/null

  ok "Repositório GitHub CLI configurado"
}

# -----------------------------------------------------------------------------
# Repositório VS Code (idempotente)
# -----------------------------------------------------------------------------

setup_vscode_repo() {
  local KEY="/etc/apt/keyrings/packages.microsoft.gpg"
  local SOURCES="/etc/apt/sources.list.d/vscode.sources"

  if [ -f "$KEY" ] && [ -f "$SOURCES" ]; then
    skip "repositório do VS Code"
    return 0
  fi

  log "Configurando repositório oficial do VS Code"

  sudo install -d -m 0755 /etc/apt/keyrings

  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor \
    | sudo tee "$KEY" >/dev/null
  sudo chmod a+r "$KEY"

  sudo tee "$SOURCES" >/dev/null <<VSCODE_REPO
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64,arm64,armhf
Signed-By: ${KEY}
VSCODE_REPO

  ok "Repositório VS Code configurado"
}

# -----------------------------------------------------------------------------
# Instalar apps via APT (idempotente)
# -----------------------------------------------------------------------------

install_apt_apps() {
  log "Instalando gh e VS Code"

  sudo apt-get update -q
  sudo apt-get install -y gh code git git-lfs
  ok "gh, code, git, git-lfs prontos"
}

# -----------------------------------------------------------------------------
# Google Chrome (idempotente)
# -----------------------------------------------------------------------------

install_google_chrome() {
  if command_exists google-chrome; then
    skip "Google Chrome (já instalado: $(google-chrome --version 2>/dev/null || true))"
    return 0
  fi

  log "Instalando Google Chrome"

  ARCH="$(dpkg --print-architecture)"

  if [ "$ARCH" != "amd64" ]; then
    echo "Google Chrome oficial ignorado: arquitetura '$ARCH'."
    echo "Instale manualmente: sudo apt install chromium || sudo snap install chromium"
    return 0
  fi

  CHROME_DEB="/tmp/google-chrome-stable_current_amd64.deb"
  wget -q -O "$CHROME_DEB" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  sudo apt-get install -y "$CHROME_DEB"
  rm -f "$CHROME_DEB"
  ok "Google Chrome instalado"
}

# -----------------------------------------------------------------------------
# AWS CLI v2 (idempotente — usa --update se já existir)
# -----------------------------------------------------------------------------

install_aws_cli() {
  log "Instalando ou atualizando AWS CLI v2"

  TMP_DIR="$(mktemp -d)"
  cd "$TMP_DIR"

  case "$(uname -m)" in
    x86_64)       AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
    aarch64|arm64) AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
    *)
      echo "AVISO: AWS CLI ignorado — arquitetura '$(uname -m)' não suportada."
      cd ~; rm -rf "$TMP_DIR"
      return 0
      ;;
  esac

  curl -fsSL "$AWS_CLI_URL" -o awscliv2.zip
  unzip -q awscliv2.zip

  if command_exists aws; then
    sudo ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update
    ok "AWS CLI atualizado"
  else
    sudo ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli
    ok "AWS CLI instalado"
  fi

  cd ~
  rm -rf "$TMP_DIR"
}

# -----------------------------------------------------------------------------
# Node.js via nvm (idempotente)
# -----------------------------------------------------------------------------

install_node() {
  log "Verificando Node.js / nvm"

  NVM_DIR="${HOME}/.nvm"

  # Carregar nvm se já instalado (necessário em shell novo onde nvm não foi sourced)
  if [ -d "$NVM_DIR" ]; then
    set +u
    # shellcheck source=/dev/null
    [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
    set -u
  fi

  if [ -d "$NVM_DIR" ] && command_exists node; then
    skip "nvm e Node.js ($(node --version))"
    return 0
  fi

  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash

  export NVM_DIR="$NVM_DIR"
  set +u
  # shellcheck source=/dev/null
  [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
  nvm install --lts
  nvm use --lts
  set -u
  ok "Node.js $(node --version) instalado via nvm"
}

# -----------------------------------------------------------------------------
# Claude Code (idempotente)
# -----------------------------------------------------------------------------

install_claude_code() {
  log "Verificando Claude Code"

  # Garantir que npm está disponível
  export NVM_DIR="${HOME}/.nvm"
  set +u
  # shellcheck source=/dev/null
  [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh" || true
  set -u

  if ! command_exists npm; then
    echo "AVISO: npm não encontrado. Instale Node.js primeiro."
    return 1
  fi

  if command_exists claude; then
    skip "Claude Code ($(claude --version 2>/dev/null || true))"
    return 0
  fi

  npm install -g @anthropic-ai/claude-code
  ok "Claude Code instalado"
}

# -----------------------------------------------------------------------------
# Limpeza (idempotente)
# -----------------------------------------------------------------------------

cleanup() {
  log "Limpando cache APT"

  sudo apt-get autoremove -y || true
  sudo apt-get clean || true
  sudo rm -rf /var/lib/apt/lists/partial/* 2>/dev/null || true

  echo
  df -h /
}

# -----------------------------------------------------------------------------
# Validação final
# -----------------------------------------------------------------------------

validate_installation() {
  log "Validação final"

  # Carregar nvm para validar node/claude
  export NVM_DIR="${HOME}/.nvm"
  set +u
  # shellcheck source=/dev/null
  [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh" || true
  set -u

  for tool in git "git lfs" gh aws code "google-chrome" node npm claude; do
    VERSION=$(eval "$tool --version" 2>/dev/null | head -1 || true)
    if [ -n "$VERSION" ]; then
      printf "  %-20s %s\n" "$tool" "$VERSION"
    else
      printf "  %-20s %s\n" "$tool" "(não encontrado)"
    fi
  done

  echo
  echo "Pacotes segurados:"
  apt-mark showhold | grep -E '^linux|kdump' || echo "  (nenhum)"

  echo
  echo "dpkg audit:"
  AUDIT_OUT="$(sudo dpkg --audit 2>&1)"
  [ -z "$AUDIT_OUT" ] && echo "  (limpo)" || echo "$AUDIT_OUT"

  echo
  echo "Memória e swap:"
  free -h

  echo
  echo "Espaço no persistence:"
  df -h /
}

# -----------------------------------------------------------------------------
# Próximos passos
# -----------------------------------------------------------------------------

print_next_steps() {
  log "Próximos passos"

  cat <<'NEXT'
  1. Autenticar GitHub CLI:
       gh auth login

  2. Configurar AWS CLI:
       aws configure

  3. Configurar Git:
       git config --global user.name "Seu Nome"
       git config --global user.email "seu@email.com"

  4. Iniciar Claude Code no terminal do VS Code:
       claude

  5. Verificar espaço disponível no persistence:
       df -h /

  6. Rodar este script novamente a qualquer momento:
       ./bootstrap-dev-env-live.sh
       (nada será reinstalado desnecessariamente)
NEXT
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
  require_sudo
  show_environment
  repair_dpkg_state

  log "Atualizando índice do APT"
  sudo apt-get update -q

  apply_performance_tweaks
  install_base_packages
  safe_system_upgrade
  setup_github_cli_repo
  setup_vscode_repo
  install_apt_apps
  install_google_chrome
  install_aws_cli
  install_node
  install_claude_code
  repair_dpkg_state
  cleanup
  validate_installation
  print_next_steps
}

main "$@"
