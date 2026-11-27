# Rust port parity ledger

Status of every verb and component of RigForge as native (Rust only), hybrid (Rust and Bash share the work), or Bash fallback (Bash only). Today every row is **Bash fallback**: the dispatcher exists and the native-verb list is empty, so `RIGFORGE_IMPL=rust` runs exactly what `bash` runs. A pull request that makes a verb native changes its row, its evidence and the list below in the same change.

## How the implementation is chosen

- `rigforge.sh` calls `_impl_handover "$@"` as the first statement of the not-sourced block, before the verb `case`. The function lives in `util/impl-handover.sh`, which is not in the kcov include list of `tests/coverage.sh`.
- The function first asks whether the verb is native (listed in `_IMPL_NATIVE_VERBS`). If it is not, it returns at once: the selection is not read, the marker is not opened and the binary is not looked for. A verb that only exists in Bash has nothing to choose between, so nothing about the switch (an unknown value, a damaged marker, a lost binary) can stop it. This keeps a rig mining and repairable: the miner unit's `msr-apply` pre-start step, `watchdog` and `control-upgrade` run the Bash path whatever the selection says.
- Selection, for a native verb: the environment variable `RIGFORGE_IMPL` (`bash` or `rust`; unset or empty means "look further"), else the one-line marker file `.rigforge-impl` beside `rigforge.sh` (read with a shell builtin, trailing blanks and CR trimmed), else `bash`. An unknown value, or an empty or unreadable marker, is an error: a native verb never runs Bash because the selection could not be read. The variable beats the marker, so `RIGFORGE_IMPL=bash` always leaves a broken selection. Units run with no environment and call `rigforge.sh`, so the marker is what reaches them; no unit template changes.
- Binary: `RIGFORGE_BIN`, else `<script directory>/bin/rigforge-rs`. With `rust` selected, a native verb needs the binary: one that is not a regular executable file is an error, and the message names the binary, the marker when the selection came from it, and `run with RIGFORGE_IMPL=bash`.
- A verb in `_IMPL_NATIVE_VERBS` (empty today, set only by `tests/test-impl-dispatch.sh`) is handed over with `exec -a "$0" <binary> "$@"` after exporting `RIGFORGE_HOME` and the four load-time values (`XMRIG_VERSION`, `XMRIG_COMMIT`, `RIGFORGE_APPLIANCE`, `MIN_CLOCK_PCT`). `execfail` plus `set +e` turn a file that cannot be executed into the error above; without `set +e` a Linux bash 5.2 under `set -e` exits silently on a failed `exec` even inside `||`. Every other verb runs the Bash path with the same argv, streams and exit status.
- `RIGFORGE_IMPL` is deliberately not forwarded through the `sudo` re-exec (`tests/test-sudo-env-forward.sh` pins the forwarded names); under `sudo` the marker decides. Verbs that re-exec through `sudo` (`tune`, `bios`) therefore need `sudo RIGFORGE_IMPL=bash rigforge.sh <verb>`, or a fixed marker, to repair a broken selection.
- `tests/run.sh` does not export `RIGFORGE_IMPL`. CI runs `make test-suite` once in the default mode and once with `RIGFORGE_IMPL=rust RIGFORGE_BIN=<built binary>` (job `suite` in `.github/workflows/rust.yml`). With the native list empty the second run is trivially the first; it proves that the binary builds and runs (the job starts it once) and that selecting `rust` does not disturb the Bash path. `RIGFORGE_IMPL=bash` set explicitly is shown to take the same path as unset by `tests/test-impl-dispatch.sh`, not by a second full suite run.

## Verbs

Regenerate the list of verbs with:

```bash
sed -n '/_RIGFORGE_SOURCED" = "0" \]; then/,/^fi$/p' rigforge.sh | grep -oE '^    [a-z |-]+\)' | tr -d ' )' | tr '|' '\n' | sort -u
```

Evidence for every row: the native list in `util/impl-handover.sh` is empty, and `tests/test-impl-dispatch.sh` runs `help`, `bogus-verb` and `help extra` in rust mode against a stand-in binary that records whether it was started (it never is). The same test runs them with an unknown value, with a damaged marker and with the binary missing, and gets the Bash result each time.

| Verb | Status | Notes |
| --- | --- | --- |
| `api-refresh` | Bash fallback | Timer-driven every 15 s; first verb to go native |
| `autotune`, `watchdog`, `control-apply`, `control-upgrade`, `msr-apply` | Bash fallback | Run by units |
| `setup`, `upgrade`, `uninstall`, `package-upgrade`, `apply` | Bash fallback | |
| `tune`, `bench`, `stress`, `bios` | Bash fallback | |
| `doctor`, `status`, `logs`, `start` (`up`), `stop` (`down`), `restart`, `enable`, `disable` | Bash fallback | |
| `backup`, `restore`, `support-bundle`, `completion` | Bash fallback | |
| `shared-host-check`, `shared-host-run` | Bash fallback | |
| `version` (`--version`, `-v`), `help` (`-h`, `--help`) | Bash fallback | |

Every `rigforge.sh <verb>` that a unit runs must be a verb the dispatcher knows. Regenerate with:

```bash
grep -hE 'Exec[A-Za-z]*=' systemd/*.template rigforge.sh | grep -oE 'rigforge\.sh +[a-z-]+' | awk '{print $2}' | sort -u
```

Today: `api-refresh autotune control-apply control-upgrade msr-apply watchdog`. `tests/test-impl-dispatch.sh` asserts each is a dispatcher label.

## Components

Regenerate with `ls util systemd crates`.

| Component | Status | Notes |
| --- | --- | --- |
| `rigforge.sh` verbs and functions | Bash fallback | See the verb table |
| `util/*.sh` (including `impl-handover.sh`, the dispatcher) | Bash fallback | Sourced by `rigforge.sh` |
| `util/api-server.py`, `util/control-server.py` | Python, unchanged | Run by the api and control units; not part of the refresh port |
| `systemd/*.template` | Unchanged | Only run verbs through `rigforge.sh` |
| `crates/rigforge-rs` binary | Builds, has no verbs | Dispatcher target |
| `crates/rigforge-core` library | No port logic yet | The library native verbs will use |

## Tests that cannot reach the binary

A test reaches the binary only when it runs a native verb through `rigforge.sh`. A test that sources `rigforge.sh` and calls its functions never goes through the dispatcher (the dispatcher is skipped when sourced) and stays Bash for good. Regenerate the first list with:

```bash
grep -lE 'source +"?(\$SCRIPT|\$\{SCRIPT\}|\$1|\$ROOT/rigforge\.sh)|\. +"\$SCRIPT"' tests/*.sh | sort
```

Reason for each file: it sources `rigforge.sh` (or a util file through it) and calls shell functions in-process. Files at this base: `daemon-pools.sh`, `e2e-api-refresh-profile.sh`, `e2e-pithead-allowlist.sh`, `e2e-real.sh`, `onion-proxy.sh`, `run.sh` (in-process sections; its black-box sections run `bash rigforge.sh <verb>` and do reach the binary), `test-api-refresh-liveness.sh`, `test-appliance-pools.sh`, `test-autotune-noise.sh`, `test-benchmark-support.sh`, `test-benchmark-verification.sh`, `test-config-apply-state.sh`, `test-config-atomic.sh`, `test-config-ownership.sh`, `test-config-write-safety.sh`, `test-control-firewall.sh`, `test-control-hardening.sh`, `test-control-revocation.sh`, `test-control-upgrade.sh`, `test-daemon-pools.sh`, `test-doctor-json.sh`, `test-donation-tor.sh`, `test-donation.sh`, `test-feed-identity.sh`, `test-fetch-proxy.sh`, `test-grub-edit.sh`, `test-hugepages-ceiling.sh`, `test-impl-dispatch.sh` (by design), `test-package-mode.sh`, `test-package-upgrade.sh`, `test-pool-fields.sh`, `test-randomx-mode.sh`, `test-refresh-profile.sh`, `test-revision-key.sh`, `test-root-guard.sh`, `test-shared-host-lifecycle.sh`, `test-shared-host.sh`, `test-sister-reconcile.sh`, `test-staged-rebuild.sh`, `test-stress.sh`, `test-sudo-env-forward.sh`, `test-thread-placement.sh`, `test-tune-pins.sh`, `test-uninstall-state.sh`, `test-upgrade-throttle-security.sh`, `test-watchdog-fail-safe.sh`, `test-watchdog-shared-host-guard.sh`, `test-watchdog-thermal-retry.sh`, `test-xmrig-logging.sh`, `test-xmrig-overlay.sh`.

Other files that never reach the binary, each for its own reason:

- Python tests of `util/*.py` and of Python helpers (`test-control-readiness.py`, `test-control-spool-cap.py`, `test-serve-poll.py`, `test-worker-proof.py`, `test-docs-replay.py`, `test-thread-profile.py`, `control-revocation.py`): they exercise Python code that is not ported.
- Repository and workflow checks (`test-codeql-workflow.sh`, `test-dependabot-coverage.sh`, `test-tool-pin-watch.sh`, `test-docs-clone-pin.sh`, `test-apt-feed.sh`, `test-homebrew-formula.sh`, `test-coverage-cache.sh`): they read files and run no verb.
- Tests that never start `rigforge.sh` and do not source it (they read files, drive Python or docs helpers, or exercise `util` code directly): `docs-replay-commands.sh`, `test-access-token-readiness.sh`, `test-api-allowlist-linux.sh`, `test-appliance-pool-control.sh`, `test-contract-credentials.sh`, `test-control-replay.sh`, `test-l3-units.sh`, `test-perf-submission.sh`, `test-stratum-auth-gate.sh`, `test-summary-diagnostics.sh`, `test-worker-proof.sh`.
- Tests that only read or source `rigforge.sh` text for one function: `test-api-allowlist-probe.sh`, `test-refresh-window-control.sh`, `test-suite-liveness.sh`, `prove-daemon.py`.
- `test-stock-home.sh` runs `sudo ./rigforge.sh` against a stock home and so reaches the dispatcher; it needs sudo and real system state, which the port does not change, and a native verb pull request must run it by hand.
- Test-harness self-tests and rig gates that start no verb: `test-e2e-apt-prereqs.sh`, `test-e2e-config-ownership.sh`, `test-e2e-docs-guest.sh`, `test-e2e-donation.sh`, `test-e2e-gate-fail-closed.sh`, `test-e2e-hammer.sh`, `test-e2e-selftest.sh`.
- Completeness check: every file under `tests/` (skipping `e2e*` and `smoke.sh`) must appear by name in this file; regenerate the unnamed ones with `for f in tests/*.sh tests/*.py; do b=$(basename "$f"); case $b in e2e*|smoke.sh) continue;; esac; grep -q "$b" docs/dev/rust-port/PARITY.md || echo "$b"; done`.
- Rig, container and release gates (`tests/e2e*.sh`, `tests/e2e/`, `smoke.sh`, `e2e-real.sh`, `docs_replay.py`): they need a real rig, root, containers or a KVM guest and are not part of `make test-suite`.
- The `tests/run.sh` section that runs `api-refresh` through the dispatcher asserts an empty string on Linux (`assert_contains ... ""`), so it proves nothing about the binary; the first native `api-refresh` pull request must add a differential test.

## Runtime dependencies

`python3` and `jq` both remain runtime dependencies. `rigforge.sh` uses `jq` throughout (config parsing, the API response files), and the api and control units run `/usr/bin/python3` on `util/api-server.py` and `util/control-server.py`. The binary uses the Rust standard library only and adds no runtime dependency; the native `api-refresh` will still run the local `jq` for canonical bytes where the design requires byte parity. `jq` can be dropped only when every verb that calls it is native; `python3` only when both servers are replaced. Neither is planned in this program.

## Coverage floor

- The kcov job runs `tests/run.sh` alone over the fixed list in `tests/coverage.sh`; `tests/coverage-floor.txt` is the committed floor. It measures Bash only. Rust code is never measured by kcov.
- The only lines this change adds to a listed file are the `source` line and the `_impl_handover "$@"` line in `rigforge.sh`; both run on every start, including under `tests/run.sh` with no binary, so the 90 percent patch gate sees them executed. The dispatcher body is in `util/impl-handover.sh` and the new test is `tests/test-impl-dispatch.sh`; neither is in the include list, so neither moves the floor.
- Proof of the dispatcher is therefore the new test (run by `make test-suite`), not kcov.
- A native verb stops running some shell lines in rust mode, but kcov never runs rust mode, so the floor is unaffected. Its Bash path stays covered by the default run. The proof for the native side is Rust unit tests and the differential test in the pull request that adds the verb.
- Every pull request that moves shell logic to Rust keeps the shell function until the verb is native in every supported setup, so the floor cannot fall because code left the listed files without its tests leaving too. If it must be deleted, that pull request lowers the floor row with the evidence.

## Owed by later pull requests

- Native verb criterion from issue 706: the binary honours `SYSTEMD_DIR` and a stand-in `systemctl` found through `PATH`. It cannot be tested while no verb is native; the first native verb pull request adds that test.
- Persistence: units reach the selection through the marker, not an `Environment=` line (decision D3). Delivery (issue 709) must install the binary by `mv` of a finished file, write the marker only after the installed binary prints a `--version` equal to the `VERSION` file, and never write the marker where the binary is absent. The dispatcher starts no extra program to check this on every tick. A lost binary or a damaged marker stops only native verbs. The pull request that makes `msr-apply`, `watchdog`, `control-apply` or `control-upgrade` native must say what a rig does in that state, because the miner unit runs `msr-apply` before every start and `control-upgrade` is the remote repair path. Delivery must write the marker by `mv` of a finished file too, so a power cut cannot leave it empty.
- Checklist for the pull request that makes the first verb native:
  - List every alias of the verb's case group in `_IMPL_NATIVE_VERBS` (`start` and `up`, `stop` and `down`, `version`, `--version` and `-v`, `help`, `-h` and `--help`). The list is compared with the first argument as typed.
  - Add a sentinel that the rust-mode CI job asserts, so a native verb that ran Bash turns the job red.
  - Make `doctor` report the selection and whether the binary is usable, because a non-native verb no longer shows a broken selection.
  - For `api-refresh`: `install_api` ends with `systemctl start rigforge-api-refresh.service || return 1`, so a broken selection would fail `setup`, `apply` and `upgrade`. Check the binary at install, or make that start best effort.
- A native `tune` or `bios` must forward `RIGFORGE_IMPL` through the `sudo` re-exec, or `RIGFORGE_IMPL=bash` stops being a way out for them.
- Delivery (issue 709), in addition: write the marker with mode 644 and the binary with mode 755, because an operator runs read-only verbs without root. A Homebrew upgrade replaces the tree and drops the marker, so delivery writes it again. Bash runs an executable text file without a `#!` line as a script, so the `--version` check above is what tells a real binary from a stray file.
- An empty first argument (`rigforge.sh ""`) reaches a native `setup` as one empty argument, where Bash drops it.
- Early hand-over for native verbs (decision D21) and the proof that the binary reproduces what the skipped shell lines did for that verb.
- Ledger of deliberate Rust and Bash differences: none yet, since no verb is native.

## Root guard

`util/root-guard.sh` lists the paths that `setup`, `upgrade` and `control-upgrade` check before they act as root (`_root_guard_check`). The binary is code root executes and the marker changes what root executes, so `.rigforge-impl`, `bin` and `bin/rigforge-rs` are now checked there when they exist: one that is not owned by root, or is writable by another group or by everyone, makes those verbs refuse the tree like any other trusted path. Absent paths are skipped, so trees without a binary behave as before. Other files in `bin` are not checked. The guard does not run for other verbs, and the hand-over runs before it, so a pull request that makes `setup`, `upgrade` or `control-upgrade` native must repeat the guard on the Rust side. A binary outside the tree through `RIGFORGE_BIN` is not covered; the variable is an operator or test setting and is not read from a unit. Test: `tests/test-impl-dispatch.sh`.
