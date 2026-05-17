# Bootstrap de Ambiente Dev em Ubuntu Live Persistence

Ambiente portátil de desenvolvimento em pendrive com Ubuntu Live Persistence.

Ferramentas instaladas:

- Git + Git LFS
- GitHub CLI (`gh`)
- AWS CLI v2
- Visual Studio Code
- Google Chrome
- Node.js (via nvm, LTS)
- Claude Code (`@anthropic-ai/claude-code`)
- Pacotes base (`curl`, `wget`, `jq`, `gpg`, `build-essential`, etc.)
- Otimizações de performance: zRAM, swappiness, noatime

## Design

### Idempotente

O script é seguro para rodar múltiplas vezes. Cada etapa verifica se já foi executada antes de agir:

- Pacotes APT já instalados são pulados.
- Repositórios já configurados não são reconfigurados.
- Google Chrome já instalado não é baixado novamente.
- AWS CLI já instalado é apenas atualizado (`--update`).
- nvm e Node.js já instalados são pulados.
- Claude Code já instalado é pulado.
- Otimizações de performance já aplicadas são puladas.

### Proteções Live Persistence

Em Ubuntu Live Persistence o sistema usa overlay e mídia parcialmente somente-leitura. Upgrades de kernel podem causar erros como:

```text
update-initramfs is disabled since running on read-only media
mkinitramfs: failed to determine device for /
dpkg: error processing package linux-image-... (--configure)
```

O script detecta automaticamente se está rodando em modo Live e aplica:

- Remoção e desativação do `kdump-tools`.
- Bloqueio via `apt pin` de upgrades de kernel.
- Marcação com `apt-mark hold` de todos os pacotes de kernel instalados.
- Reparo do estado do `dpkg` antes e depois das instalações.

### Otimizações de performance

Pendrives têm velocidade de escrita muito inferior à leitura. O script aplica:

| Otimização | O que faz |
|---|---|
| **zRAM** | Cria swap comprimido na RAM — elimina escritas de swap no pendrive |
| **swappiness=10** | Sistema usa RAM ao máximo antes de recorrer ao swap |
| **vfs_cache_pressure=50** | Mantém cache de filesystem em memória por mais tempo |
| **noatime** | Elimina atualização de timestamp a cada leitura de arquivo |

## Estrutura do repositório

```text
machine-bootstrap/
├── README.md
└── scripts/
    └── bootstrap-dev-env-live.sh
```

## Uso

### Primeira vez ou após clonar

```bash
git clone https://github.com/SEU_USUARIO/machine-bootstrap.git
cd machine-bootstrap
chmod +x scripts/bootstrap-dev-env-live.sh
./scripts/bootstrap-dev-env-live.sh
```

### Rodar novamente (após reiniciar o pendrive, por exemplo)

```bash
./scripts/bootstrap-dev-env-live.sh
```

O que já estiver instalado e configurado será pulado automaticamente.

### Comando rápido via curl

```bash
curl -fsSL https://raw.githubusercontent.com/SEU_USUARIO/machine-bootstrap/main/scripts/bootstrap-dev-env-live.sh \
  -o bootstrap-dev-env-live.sh
chmod +x bootstrap-dev-env-live.sh
./bootstrap-dev-env-live.sh
```

## Validação

### Após a instalação

```bash
git --version
git lfs version
gh --version
aws --version
code --version
google-chrome --version
node --version
npm --version
claude --version
```

### Verificar dpkg

```bash
sudo dpkg --audit
```

Saída vazia indica que não há pacotes quebrados.

### Verificar espaço no persistence

```bash
df -h /
```

### Verificar pacotes de kernel segurados

```bash
apt-mark showhold | grep -E '^linux|kdump'
```

### Verificar otimizações de memória

```bash
# swappiness atual
cat /proc/sys/vm/swappiness

# swap ativo (deve mostrar dispositivo zram)
swapon --show

# uso de memória e swap
free -h
```

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

### Claude Code

O Claude Code roda no terminal. Dentro do VS Code, abra o terminal integrado e use:

```bash
claude
```

## Recuperação manual em caso de dpkg quebrado

Se o sistema já estiver com dpkg quebrado por causa de `kdump-tools` ou kernel:

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
sudo dpkg --audit
```

## Liberação de espaço no persistence

```bash
sudo apt autoremove -y
sudo apt clean
df -h /
```

## Resultado esperado ao final

```text
git              ✓
git lfs          ✓
gh               ✓
aws              ✓
code (VS Code)   ✓
google-chrome    ✓
node (LTS)       ✓
npm              ✓
claude           ✓
```

Otimizações ativas:

```text
zRAM             ✓  (swap comprimido na RAM)
swappiness=10    ✓  (prioriza RAM)
noatime          ✓  (sem writes desnecessários)
kernel hold      ✓  (sem upgrade de kernel)
```
