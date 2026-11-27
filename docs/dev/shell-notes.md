# Shell notes

Bash behaviour that shapes how `rigforge.sh` is written, kept here instead of in source comments.

## Guard inside the command substitution

Under `set -E` with an ERR trap, bash 3.2 does not carry a suppressed errexit into a `$( )` child.
A caller-side `x=$(cmd) || true` therefore still fires the ERR trap inside the child. Put the guard
inside the substitution, as the watchdog does for its strike counter:
`f=$(cat "$fails_f" 2>/dev/null || true)` (#210, #364).

The watchdog's `hr=$(_read_api_hashrate)` is left unguarded on purpose: the reader swallows curl's
refused or timed-out exit itself and returns empty, which the watchdog counts as a strike (#364).
