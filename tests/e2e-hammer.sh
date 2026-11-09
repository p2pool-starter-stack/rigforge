#!/usr/bin/env bash

hammer_start() {
    [ "$#" -gt 0 ] || return 2
    local had_m=0
    case $- in *m*) had_m=1 ;; esac
    set -m
    (
        exec 9<&-
        while :; do
            "$@" >/dev/null 2>&1 || true
        done
    ) &
    local pid=$!
    [ "$had_m" = 1 ] || set +m
    HAMMER_PIDS="${HAMMER_PIDS:+$HAMMER_PIDS }$pid"
}

hammer_stop() {
    local p
    for p in ${HAMMER_PIDS:-}; do
        kill -KILL -- "-$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null || true
        wait "$p" 2>/dev/null || true
        kill -KILL -- "-$p" 2>/dev/null || true
    done
    HAMMER_PIDS=""
    return 0
}
