#!/usr/bin/env bash
set -euo pipefail

COMPOSE="$(dpkg -s docker-compose-plugin 2>/dev/null | grep '^Status:' || true)"
ARCH="$(dpkg --print-architecture)"
SYSBOX_SHA256="87cfa5cad97dc5dc1a243d6d88be1393be75b93a517dc1580ecd8a2801c2777a"
SYSBOX_URL="https://downloads.nestybox.com/sysbox/releases/v0.6.6/sysbox-ce_0.6.6-0.linux_amd64.deb"


log() { echo "[INFO] $*"; }

if [[ $EUID -ne 0 ]]; then
    log "This script must be run as root (sudo)." >&2
    exit 1
fi

read -rp "We will install missing dependencies to run compose and we will stop your current containers and docker service, are you sure you want to continue? [y/N] " resp
[[ "$resp" =~ ^[Yy]$ ]] || { log "Aborting."; exit 1; }

if ! command -v docker &>/dev/null; then
    read -rp "Docker not found. Do you want to install it? [y/N] " install_docker
    if [[ "$install_docker" =~ ^[Yy]$ ]]; then
        log "Installing Docker..."
        curl -fsSL https://get.docker.com | bash
    else
        log "Installation aborted because Docker is required."
        exit 1
    fi
else
    log "Docker is installed."
fi


log "Updating repos APT..."
DEBIAN_FRONTEND=noninteractive apt-get update -qq

if [[ "$COMPOSE" == "Status: install ok installed" ]]; then
    log "docker-compose-plugin installed"
else
    log "Installing docker-compose-plugin..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin
fi

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

    if docker ps -q | grep -q .; then
        log "Containers:"
        docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"
        read -rp "Do you want to stop all running containers?? [y/N] " stop_containers
        if [[ "$stop_containers" =~ ^[Yy]$ ]]; then
            docker ps -q | xargs -r docker stop
            systemctl stop docker
        else
            log "Aborted the containers stops. We can't install sysbox without stopping Docker."
            exit 1
        fi
    fi
    
    if [[ "$ARCH" != "amd64" ]]; then
        log "Unsupported architecture: $ARCH. Only amd64 is supported."
        exit 1
    fi

    wget --timeout=30 --tries=3 -qO "$TMP_DEB" "$SYSBOX_URL" >> "$LOGFILE"
    
    if ! echo "$SYSBOX_SHA256  $TMP_DEB" | sha256sum -c -; then
        log "Checksum incorrect, aborting."
        exit 1
    fi
    
    dpkg -i "$TMP_DEB" >>"$LOGFILE" 2>&1
    apt-get install -f -y >>"$LOGFILE" 2>&1
    
    if ! command -v sysbox-runc &>/dev/null; then
        log "sysbox-runc not found, please checking $LOGFILE"
        exit 1
    else
        log "sysbox-ce installed successfully"
    fi
fi

read -rp "To complete the installation we need to restart the machine. Do you want to restart now? [y/N] " resp_reboot
if [[ "$resp_reboot" =~ ^[yY]$ ]]; then
    log "Rebooting..."
    sleep 3
    reboot
else
    log "Installation complete. Please reboot the machine manually when possible."
    systemctl start docker
    docker container ls -a -q | xargs -r docker start
fi                                                                                                                                     
~                                                   
