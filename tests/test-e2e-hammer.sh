# shellcheck shell=bash disable=SC2016,SC2034
echo "== unit: api-impact hammer dies with the phase and never holds the rig-lock fd (#653) =="
source "$ROOT/tests/e2e-hammer.sh"
H653="$(mktemp -d "$SANDBOX/hammer653.XXXXXX")"
: >"$H653/lock"

h653_wait_for() {
    local i=0
    while [ ! -e "$1" ] && [ "$i" -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    [ -e "$1" ]
}
h653_alive() {
    kill -0 "$1" 2>/dev/null || return 1
    local st
    st="$(sed -n 's/^[0-9]* (.*) \(.\).*/\1/p' "/proc/$1/stat" 2>/dev/null || true)"
    [ -n "$st" ] || st="$(ps -o stat= -p "$1" 2>/dev/null | cut -c1)"
    [ "$st" != Z ]
}
h653_assert_file_eq() { assert_eq "$1" "$(cat "$2" 2>/dev/null)" "$3"; }
h653_assert_ge() { assert_eq "$1" "$([ "$2" -ge "$3" ] 2>/dev/null && echo yes)" yes; }

(
    exec 9<"$H653/lock"
    [ -e /dev/fd/9 ] && printf yes >"$H653/fd9-visible"
    hammer_start sh -c "printf '%s' \$\$ >'$H653/green.child'; if [ -e /dev/fd/9 ]; then echo open >'$H653/green.fd9'; else echo closed >'$H653/green.fd9'; fi; exec sleep 60"
    if h653_wait_for "$H653/green.child"; then
        green_child="$(cat "$H653/green.child")"
        h653_alive "$green_child" && printf alive >"$H653/green.pre"
        hammer_stop
        printf '%s' "$?" >"$H653/green.stop-rc"
        printf '%s' "$HAMMER_PIDS" >"$H653/green.left"
        gone=0
        for _ in $(seq 30); do
            h653_alive "$green_child" || {
                gone=1
                break
            }
            sleep 0.1
        done
        printf '%s' "$gone" >"$H653/green.gone"
    fi
)
assert_eq "api-impact hammer: the stub request started (#653)" "$([ -s "$H653/green.child" ] && echo started)" started
h653_assert_file_eq "api-impact hammer: the request was still running just before the stop (#653)" "$H653/green.pre" alive
h653_assert_file_eq "api-impact hammer: hammer_stop returns 0 (#653)" "$H653/green.stop-rc" 0
h653_assert_file_eq "api-impact hammer: hammer_stop clears the pid list (#653)" "$H653/green.left" ""
h653_assert_file_eq "api-impact hammer: the running request dies with the phase (#653)" "$H653/green.gone" 1
if [ -f "$H653/fd9-visible" ]; then
    h653_assert_file_eq "api-impact hammer: the request inherits no copy of the rig-lock fd (#653)" "$H653/green.fd9" closed
else
    echo "  SKIP: no /dev/fd on this host — the fd-inheritance row runs in the Linux CI jobs"
fi

(
    exec 9<"$H653/lock"
    (
        while :; do
            sh -c "printf '%s' \$\$ >'$H653/red.child'; if [ -e /dev/fd/9 ]; then echo open >'$H653/red.fd9'; else echo closed >'$H653/red.fd9'; fi; exec sleep 60" >/dev/null 2>&1 || true
        done
    ) &
    red_pid=$!
    if h653_wait_for "$H653/red.child"; then
        red_child="$(cat "$H653/red.child")"
        kill "$red_pid" 2>/dev/null || true
        sleep 0.3
        kill -0 "$red_child" 2>/dev/null && printf alive >"$H653/red.survived"
        kill -9 "$red_child" 2>/dev/null || true
    fi
)
h653_assert_file_eq "api-impact hammer: the pre-#653 shape left its request holding a live rig-lock fd copy (#653)" "$H653/red.survived" alive
if [ -f "$H653/fd9-visible" ]; then
    h653_assert_file_eq "api-impact hammer: that surviving request still held the inherited fd (#653)" "$H653/red.fd9" open
fi

(
    exec 9<"$H653/lock"
    : >"$H653/ticks"
    hammer_start sh -c "printf x >>'$H653/ticks'; sleep 0.2"
    hammer_start sh -c "printf x >>'$H653/ticks'; sleep 0.2"
    printf '%s\n' $HAMMER_PIDS | grep -c . >"$H653/ticks.pids"
    sleep 1
    hammer_stop
    sleep 0.4
    wc -c <"$H653/ticks" | tr -d ' ' >"$H653/ticks.mid"
    sleep 0.4
    wc -c <"$H653/ticks" | tr -d ' ' >"$H653/ticks.after"
    printf '%s' "$HAMMER_PIDS" >"$H653/ticks.left"
)
assert_eq "api-impact hammer: each hammer_start records exactly one pid (#653)" "$(cat "$H653/ticks.pids" 2>/dev/null)" "2"
h653_assert_ge "api-impact hammer: a running hammer keeps issuing requests back to back (#653)" "$(cat "$H653/ticks.mid" 2>/dev/null)" 2
assert_eq "api-impact hammer: nothing hits the endpoint after hammer_stop (#653)" "$(cat "$H653/ticks.after" 2>/dev/null)" "$(cat "$H653/ticks.mid" 2>/dev/null)"
assert_eq "api-impact hammer: the pid list is empty after the stop (#653)" "$(cat "$H653/ticks.left" 2>/dev/null)" ""

PH653="$(sed -n '/^phase_api_impact()/,/^}/p' "$ROOT/tests/e2e-pithead.sh")"
assert_contains "phase_api_impact starts its load through hammer_start (#653)" "$PH653" "hammer_start curl"
assert_contains "phase_api_impact stops its load through hammer_stop (#653)" "$PH653" "hammer_stop"
assert_absent "phase_api_impact keeps no raw pid-only kill loop (#653)" "$PH653" 'kill "$p"'
assert_absent "phase_api_impact starts no bare background subshell (#653)" "$PH653" ") &"
