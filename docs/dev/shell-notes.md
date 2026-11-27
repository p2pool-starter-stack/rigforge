# Shell notes

Bash behaviour that shapes how `rigforge.sh` is written, kept here instead of in source comments.

## Guard inside the command substitution

Under `set -E` with an ERR trap, bash 3.2 does not carry a suppressed errexit into a `$( )` child.
A caller-side `x=$(cmd) || true` therefore still fires the ERR trap inside the child. Put the guard
inside the substitution, as the watchdog does for its strike counter:
`f=$(cat "$fails_f" 2>/dev/null || true)` (#210, #364).

The watchdog's `hr=$(_read_api_hashrate)` is left unguarded on purpose: the reader swallows curl's
refused or timed-out exit itself and returns empty, which the watchdog counts as a strike (#364).

## Implementation hand-over and the top of the dispatcher

- `_impl_handover "$@"` is the first statement of the not-sourced block, before the extra-argument check, so a native verb is handed over before any Bash work for it. It returns at once for a verb that is not native, without reading the selection, so an unknown value, a damaged marker or a missing binary is an error for a native verb only. See [PARITY.md](rust-port/PARITY.md).
- A failed `exec` under `set -e` makes bash 5.2 exit silently even inside `exec ... || error`, so the handover runs `set +e` before `exec` and calls `error` on the line after it.
- The extra-argument check rejects stray words for verbs that take no arguments (Pithead's `setup --skip-deps` habit, a typo'd `apply --now`) instead of running as if nothing was passed. Verbs with their own flags validate in their own loops.
- `CURRENT_STEP="running '<verb>'"` names the verb before dispatch so an unexpected failure reports where it happened, not the stale "starting up" default (#353). `setup`'s `main()` overwrites it a moment later.
- `setup` shifts with `if [ $# -gt 0 ]; then shift; fi`, not `[ $# -gt 0 ] && shift`: a false `&&` list at top level trips `set -e` on the zero-argument default path.
- The ERR trap is installed only when the script is not sourced, so the test suite can source it.
