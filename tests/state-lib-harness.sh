#!/usr/bin/env bash
set -uo pipefail
CODE="$1"
OUT="$2"
BIN="$3"
mkdir -p "$OUT"
(
    export PATH="$BIN:$PATH"
    source "$CODE/rigforge.sh"
    OS_TYPE=Linux
    SYSTEMD_DIR="$OUT"
    REAL_USER=rfop
    WORKER_ROOT="$OUT/worker"
    mkdir -p "$WORKER_ROOT"
    BUILD_DIR="$WORKER_ROOT/xmrig/build"
    CPUPOWER_PATH=/usr/bin/cpupower
    NFT_PATH=/usr/sbin/nft
    export BUILD_DIR CPUPOWER_PATH NFT_PATH
    MINER_USER=rfminer
    SERVICE_NAME=xmrig
    API_MODE=enabled API_BIND=0.0.0.0 API_PORT=8081
    CONTROL_MODE=enabled CONTROL_BIND=0.0.0.0 CONTROL_PORT=8082 CONTROL_UPGRADE=enabled
    API_ALLOW_FROM=10.0.0.5 ACCESS_TOKEN=tok-secret
    AUTOTUNE_MODE=performance AUTOTUNE_TARGET=perf
    WATCHDOG_MODE=enabled WATCHDOG_INTERVAL_MIN=5
    RIGFORGE_APPLIANCE=0
    _wait_sister_api() { :; }
    _ensure_miner_user() { :; }
    _render_xmrig_unit
    install_autotune
    install_watchdog
    install_api
    install_control
) >"$OUT/.log" 2>&1
