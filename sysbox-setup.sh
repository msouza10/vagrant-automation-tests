#!/usr/bin/env bash
set -euo pipefail

# auto passing
ASSUME_YES=false
for arg in "$@"; do
  [[ $arg == "-y" ]] && ASSUME_YES=true && break
done

confirm() {
  local prompt="$1"
  if $ASSUME_YES; then
    return 0
  fi
  local reply
  read -rp "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# variables
DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
CLI_PLUGINS_DIR="$DOCKER_CONFIG/cli-plugins"
ARCH="$(dpkg --print-architecture)"
SYSBOX_SHA256="87cfa5cad97dc5dc1a243d6d88be1393be75b93a517dc1580ecd8a2801c2777a"
SYSBOX_URL="https://downloads.nestybox.com/sysbox/releases/v0.6.6/sysbox-ce_0.6.6-0.linux_amd64.deb"

# log builder
log() { echo "[INFO] $*"; }

# root check

if [[ $EUID -ne 0 ]]; then
    log "This script must be run as root (sudo)." >&2
    exit 1
fi

# starting code
log "Updating repos APT..."
DEBIAN_FRONTEND=noninteractive apt-get update -qq

# Confirmation number 1
confirm "We will install missing dependencies to run compose and we will stop your current containers and docker service, are you sure you want to continue?" \
  || { log "Aborting."; exit 1; }

# functions
docker_install () {
    if ! command -v docker &>/dev/null; then
        # confirmation number 2
        confirm "Docker not found. Do you want to install it?" \
            || { log "Docker is needed. Abort."; exit 1; }
        log "Installing Docker..."
        curl -fsSL https://get.docker.com | bash
    else
        log "Docker is installed."
    fi
}

docker-ce_install() {
    log "Configuring docker-compose plugin..."
    if [[ -x "$CLI_PLUGINS_DIR/docker-compose" ]] || command -v docker-compose &>/dev/null; then
        log "docker-compose-plugin is installed"
    else
        log "Try install docker-compose-plugin by apt repo..."
        if DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin; then
            log "installed by apt repo"
        else
            log "apt repo failed, installing docker-compose by offical script..."
            mkdir -p "$CLI_PLUGINS_DIR"
            curl -SL "https://github.com/docker/compose/releases/download/v2.35.1/docker-compose-linux-x86_64" \
                -o "$CLI_PLUGINS_DIR/docker-compose"
            chmod +x "$CLI_PLUGINS_DIR/docker-compose"
            log "docker-compose installed in $CLI_PLUGINS_DIR/docker-compose"
        fi
    fi
}

sysbox_install(){
    if command -v sysbox-runc &>/dev/null; then
        log "sysbox-runc installed"
    else
        log "sysbox-runc not found. Installing sysbox-ce and depends..."
        
        for cmd in wget mktemp jq; do
            if ! command -v "$cmd" &>/dev/null; then
                log "Installing depends $cmd"
                DEBIAN_FRONTEND=noninteractive apt-get install -y "$cmd"
            fi
        done

        TMP_DEB="$(mktemp --suffix=.deb)"
        LOGDIR="$(dirname "$TMP_DEB")"
        LOGFILE="$LOGDIR/sysbox-install.log"
        mkdir -p "$LOGDIR"

        # condition for tmp directory clean
        cleanup(){
            exit_code=$?
            if [[ $exit_code -eq 0 ]]; then
                [[ -f "$TMP_DEB" ]] && rm -f "$TMP_DEB"
                [[ -f "$LOGFILE" ]] && rm -f "$LOGFILE"
            else
                log "Failed — preserved .deb in $TMP_DEB and logs in $LOGFILE"
            fi
        }

        trap cleanup EXIT

        # Condition for stopping containers PS: preciso pensar em uma forma de guardar os containers em exec da forma que esta hoje quando iniciar vai pegar coisas antigas tambem :D
        if docker ps -q | grep -q .; then
            log "Containers:"
            docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"
            if confirm "stop all containers and docker service?"; then
                docker ps -q | xargs -r docker stop
                systemctl stop docker
            else
                log "Cannot install without stopping Docker. Aborting."
                exit 1
            fi
        fi
        
        if [[ "$ARCH" != "amd64" ]]; then
            log "Unsupported architecture: $ARCH. Only amd64 is supported."
            exit 1
        fi

        # PReciso encontrar uma forma de deixar isso melhor, hoje estamos com um versao fixada e nao busca novas versoes. - ideas 
        # latest_url=$(curl -s https://api.github.com/repos/nestybox/sysbox/releases/latest | jq -r '.assets[] | select(.name | endswith(".deb")) | .browser_download_url')
        wget --timeout=30 --tries=3 -qO "$TMP_DEB" "$SYSBOX_URL" >> "$LOGFILE"
        
        if ! echo "$SYSBOX_SHA256  $TMP_DEB" | sha256sum -c -; then
            log "Checksum incorrect, aborting."
            exit 1
        fi
        
        log "Installing sysbox package with dependency resolution..."
        apt-get update >> "$LOGFILE" 2>&1
        dpkg -i "$TMP_DEB" >> "$LOGFILE" 2>&1 || true
        apt-get install -f -y >> "$LOGFILE" 2>&1

        # condition for validation sysbox installation
        if ! command -v sysbox-runc &>/dev/null; then
            log "sysbox-runc not found, please checking $LOGFILE"
            exit 1
        else
            log "sysbox-ce installed successfully"
        fi
    fi
}

# —————— exec functions ——————
docker_install
docker-ce_install
sysbox_install

if confirm "To complete the installation we need to restart the machine. Do you want to restart now?"; then
  log "Rebooting…"
  sleep 3
  reboot
else
  log "Installation complete. Please reboot manually."
  systemctl start docker
  # essa e aquela logica quebrada do docker que falei
  docker container ls -a -q | xargs -r docker start
fi
