````markdown
# Bootstrap de Ambiente Dev em Ubuntu Live Persistence

Documentação para configurar um Ubuntu em modo **Live Persistence** como ambiente portátil de desenvolvimento, instalando as ferramentas principais usadas no dia a dia:

- Git
- Git LFS
- GitHub CLI (`gh`)
- AWS CLI v2
- Visual Studio Code
- Google Chrome
- Pacotes base úteis para desenvolvimento

## Objetivo

Permitir que um pendrive com Ubuntu Live Persistence seja usado como ambiente de desenvolvimento em qualquer computador, mantendo as ferramentas instaladas entre sessões.

Este script foi pensado especificamente para ambiente **Live Persistence**, evitando problemas comuns com atualização de kernel, `initramfs` e `kdump-tools`.

## Problema tratado

Em Ubuntu Live Persistence, um `sudo apt upgrade -y` pode tentar atualizar pacotes de kernel, como:

- `linux-image-*`
- `linux-modules-*`
- `linux-headers-*`
- `linux-generic-*`

Esse tipo de atualização pode quebrar porque o sistema live usa mídia parcialmente somente-leitura e overlay. Um erro comum é:

```text
update-initramfs is disabled since running on read-only media
mkinitramfs: failed to determine device for /
dpkg: error processing package linux-image-... (--configure)
Error: Sub-process /usr/bin/dpkg returned an error code (1)
```

Para evitar isso, o script:

- detecta se está rodando em Live Persistence;
- remove/desativa `kdump-tools`;
- remove hooks problemáticos do `kdump-tools`;
- bloqueia upgrades de pacotes de kernel;
- executa `apt upgrade -y` apenas depois dessas proteções;
- tenta reparar o estado do `dpkg` caso já exista algum pacote quebrado.

## Estrutura sugerida do repositório

```text
machine-bootstrap/
├── README.md
└── scripts/
    └── bootstrap-dev-env-live.sh
```

## Criar o script

Crie o arquivo:

```bash
mkdir -p scripts
nano scripts/bootstrap-dev-env-live.sh
```

Conteúdo do script:

```bash
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

log() {
  echo
  echo "==> $1"
}

is_live_session() {
  grep -qE 'boot=casper|maybe-ubiquity' /proc/cmdline 2>/dev/null && return 0
  findmnt -n -o FSTYPE / 2>/dev/null | grep -q '^overlay$' && return 0
  mount | grep -qiE 'overlay|casper|cow|/cdrom' && return 0
  return 1
}

require_sudo() {
  if ! command -v sudo >/dev/null 2>&1; then
    echo "ERRO: sudo não encontrado. Rode como root ou instale sudo."
    exit 1
  fi
}

show_environment() {
  log "Ambiente detectado"
  echo "Hostname: $(hostname)"
  echo "Kernel atual: $(uname -r)"
  echo "Arquitetura CPU: $(uname -m)"
  echo "Arquitetura APT: $(dpkg --print-architecture)"
  echo "Root filesystem: $(findmnt -n -o FSTYPE / || true)"

  if is_live_session; then
    echo "Modo: Live/Persistence"
  else
    echo "Modo: instalação normal"
  fi

  echo
  df -h /
}

apply_live_persistence_safety() {
  if ! is_live_session; then
    log "Instalação normal detectada; não aplicando bloqueios de Live Persistence"
    return 0
  fi

  log "Aplicando proteções para Live Persistence"

  sudo systemctl disable --now kdump-tools 2>/dev/null || true

  if dpkg -s kdump-tools >/dev/null 2>&1; then
    sudo dpkg --remove --force-remove-reinstreq kdump-tools 2>/dev/null || true
    sudo apt purge -y kdump-tools 2>/dev/null || true
  fi

  sudo rm -f /etc/kernel/postinst.d/kdump-tools
  sudo rm -f /etc/kernel/postrm.d/kdump-tools

  sudo tee /etc/apt/preferences.d/99-live-no-kernel-upgrades >/dev/null <<'PIN_KERNEL'
Package: linux-generic* linux-image* linux-modules* linux-headers* linux-tools* linux-main-modules* kdump-tools
Pin: release *
Pin-Priority: -1
PIN_KERNEL

  INSTALLED_KERNEL_PACKAGES="$(
    dpkg-query -W -f='${binary:Package}\n' \
      'linux-generic*' \
      'linux-image*' \
      'linux-modules*' \
      'linux-headers*' \
      'linux-tools*' \
      'linux-main-modules*' \
      2>/dev/null \
      | sort -u \
      || true
  )"

  if [ -n "$INSTALLED_KERNEL_PACKAGES" ]; then
    echo "$INSTALLED_KERNEL_PACKAGES" | xargs -r sudo apt-mark hold || true
  fi
}

repair_dpkg_state() {
  log "Reparando estado do dpkg/APT, se necessário"

  apply_live_persistence_safety

  sudo dpkg --configure -a || true
  sudo apt -f install -y || true

  if sudo dpkg --audit | grep -q .; then
    echo
    echo "AVISO: dpkg ainda encontrou pacotes pendentes:"
    sudo dpkg --audit || true
    echo
    echo "Tentando nova correção após remover hooks problemáticos..."
    apply_live_persistence_safety
    sudo dpkg --configure -a || true
    sudo apt -f install -y || true
  fi
}

install_base_packages() {
  log "Instalando pacotes base"

  sudo apt install -y \
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
}

safe_system_upgrade() {
  log "Executando apt upgrade seguro"

  apply_live_persistence_safety

  sudo apt update
  sudo apt upgrade -y
}

setup_github_cli_repo() {
  log "Configurando repositório oficial do GitHub CLI"

  sudo install -d -m 0755 /etc/apt/keyrings

  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null

  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
}

setup_vscode_repo() {
  log "Configurando repositório oficial do VS Code"

  sudo install -d -m 0755 /etc/apt/keyrings

  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor \
    | sudo tee /etc/apt/keyrings/packages.microsoft.gpg >/dev/null

  sudo chmod a+r /etc/apt/keyrings/packages.microsoft.gpg

  sudo tee /etc/apt/sources.list.d/vscode.sources >/dev/null <<'VSCODE_REPO'
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64,arm64,armhf
Signed-By: /etc/apt/keyrings/packages.microsoft.gpg
VSCODE_REPO
}

install_apt_apps() {
  log "Instalando Git, Git LFS, GitHub CLI e VS Code"

  sudo apt update

  sudo apt install -y \
    git \
    git-lfs \
    gh \
    code
}

install_google_chrome() {
  log "Instalando Google Chrome"

  ARCH="$(dpkg --print-architecture)"

  if [ "$ARCH" != "amd64" ]; then
    echo "Google Chrome oficial ignorado: arquitetura atual é '$ARCH'."
    echo "Fallback recomendado:"
    echo "  sudo apt install -y chromium || sudo snap install chromium"
    return 0
  fi

  CHROME_DEB="/tmp/google-chrome-stable_current_amd64.deb"

  wget -O "$CHROME_DEB" \
    https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb

  sudo apt install -y "$CHROME_DEB"
  rm -f "$CHROME_DEB"
}

install_aws_cli() {
  log "Instalando ou atualizando AWS CLI v2"

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
}

cleanup() {
  log "Limpando cache"

  sudo apt autoremove -y || true
  sudo apt clean || true
  sudo rm -rf /var/lib/apt/lists/partial/* 2>/dev/null || true

  echo
  df -h /
}

validate_installation() {
  log "Validando instalação"

  echo
  echo "Git:"
  git --version || true

  echo
  echo "Git LFS:"
  git lfs version || true

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
  google-chrome --version || true

  echo
  echo "Pacotes segurados:"
  apt-mark showhold | grep -E '^linux|kdump' || true

  echo
  echo "dpkg audit:"
  sudo dpkg --audit || true
}

print_next_steps() {
  log "Próximos passos"

  cat <<'NEXT'
Autenticar GitHub CLI:
  gh auth login

Configurar AWS CLI:
  aws configure

Configurar identidade global do Git:
  git config --global user.name "Seu Nome"
  git config --global user.email "seu-email@exemplo.com"

Validar depois de reiniciar:
  git --version
  git lfs version
  gh --version
  aws --version
  code --version
  google-chrome --version

Verificar se o dpkg ficou limpo:
  sudo dpkg --audit

Verificar espaço do persistence:
  df -h /
NEXT
}

main() {
  require_sudo
  show_environment
  repair_dpkg_state

  log "Atualizando índice do APT"
  sudo apt update

  install_base_packages
  safe_system_upgrade
  setup_github_cli_repo
  setup_vscode_repo
  install_apt_apps
  install_google_chrome
  install_aws_cli
  repair_dpkg_state
  cleanup
  validate_installation
  print_next_steps
}

main "$@"
```

## Permissão de execução

```bash
chmod +x scripts/bootstrap-dev-env-live.sh
```

## Executar

```bash
./scripts/bootstrap-dev-env-live.sh
```

## Executar diretamente a partir do repositório

Quando este script estiver versionado em um repositório GitHub, ele pode ser executado em um ambiente limpo com:

```bash
git clone https://github.com/SEU_USUARIO/machine-bootstrap.git
cd machine-bootstrap
chmod +x scripts/bootstrap-dev-env-live.sh
./scripts/bootstrap-dev-env-live.sh
```

## Comando rápido usando `curl`

Caso o repositório esteja público ou acessível via URL raw:

```bash
curl -fsSL https://raw.githubusercontent.com/SEU_USUARIO/machine-bootstrap/main/scripts/bootstrap-dev-env-live.sh -o bootstrap-dev-env-live.sh
chmod +x bootstrap-dev-env-live.sh
./bootstrap-dev-env-live.sh
```

## Validação pós-instalação

Após executar o script, valide:

```bash
git --version
git lfs version
gh --version
aws --version
code --version
google-chrome --version
```

Verifique também se o `dpkg` está limpo:

```bash
sudo dpkg --audit
```

Se o comando não retornar nada, não há pacotes quebrados pendentes.

## Validação após reiniciar

Depois de reiniciar o Ubuntu Live Persistence, rode novamente:

```bash
git --version
git lfs version
gh --version
aws --version
code --version
google-chrome --version
```

Se os comandos continuarem disponíveis, a persistência está funcionando corretamente.

## Configuração pós-instalação

### Git

```bash
git config --global user.name "Seu Nome"
git config --global user.email "seu-email@exemplo.com"
```

### GitHub CLI

```bash
gh auth login
```

### AWS CLI

```bash
aws configure
```

## Verificar espaço disponível

```bash
df -h /
```

Em Live Persistence, é importante monitorar o espaço porque instalações e atualizações são gravadas no overlay persistente.

## Verificar pacotes segurados

```bash
apt-mark showhold | grep -E '^linux|kdump' || true
```

Em Live Persistence, é esperado que pacotes de kernel estejam segurados para evitar quebra em atualizações.

## Observações importantes

Não é recomendado atualizar kernel em Ubuntu Live Persistence.

O script bloqueia upgrades de kernel porque o sistema live usa overlay e mídia parcialmente somente-leitura. Atualizações de kernel podem tentar gerar `initramfs`, modificar `/boot` ou executar hooks incompatíveis com o ambiente live.

O script ainda executa:

```bash
sudo apt upgrade -y
```

Mas faz isso depois de aplicar proteções para evitar que pacotes de kernel e `kdump-tools` causem quebra no `dpkg`.

## Recuperação manual em caso de erro

Se o sistema já estiver com `dpkg` quebrado por causa de `kdump-tools` ou kernel, rode:

```bash
sudo systemctl disable --now kdump-tools 2>/dev/null || true
sudo dpkg --remove --force-remove-reinstreq kdump-tools 2>/dev/null || true
sudo apt purge -y kdump-tools 2>/dev/null || true
sudo rm -f /etc/kernel/postinst.d/kdump-tools
sudo rm -f /etc/kernel/postrm.d/kdump-tools
sudo dpkg --configure -a
sudo apt -f install -y
sudo apt autoremove -y
sudo apt clean
```

Depois valide:

```bash
sudo dpkg --audit
```

## Limpeza de cache

Para liberar espaço no persistence:

```bash
sudo apt autoremove -y
sudo apt clean
```

## Resultado esperado

Ao final da execução, o ambiente deve conter:

```text
git
git-lfs
gh
aws
code
google-chrome
curl
wget
jq
gpg
unzip
zip
build-essential
openssh-client
```

Esse setup permite usar o pendrive persistente como ambiente portátil de desenvolvimento em qualquer computador compatível.
````

