#!/usr/bin/env bash
set -Eeuo pipefail

extract() {
    local script
    script=$(awk -v name="$1" '
        BEGIN { begin="<!-- docs-replay:" name ":begin -->"; end="<!-- docs-replay:" name ":end -->" }
        $0 == begin { if (stage) bad=1; stage=1; next }
        $0 == end { if (stage != 3) bad=1; stage=4; next }
        stage == 1 && $0 == "```bash" { stage=2; next }
        stage == 2 && $0 == "```" { stage=3; next }
        stage == 1 || stage == 3 { if ($0 !~ /^[[:space:]]*$/) bad=1; next }
        stage == 2 {
            if ($0 ~ /```|<!--/) bad=1
            if ($0 !~ /^[[:space:]]*$/) nonempty=1
            body=body $0 "\n"
        }
        END { if (bad || stage != 4 || !nonempty) exit 1; printf "%s", body }
    ') || {
        echo "invalid docs replay marker: $1" >&2
        return 1
    }
    bash -n <<<"$script" || return 1
    printf '%s\n' "$script"
}

if [ "${1:-}" = --block ]; then
    extract "$2"
else
    root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    quick=$(extract quick-start <"$root/README.md")
    clone=$(extract clone <"$root/docs/getting-started.md")
    setup=$(extract setup <"$root/docs/getting-started.md")
    extract dry-run <"$root/docs/getting-started.md" >/dev/null
    extract reboot <"$root/docs/getting-started.md" >/dev/null
    [ "$quick" = "$clone"$'\n'"$setup" ] || {
        echo 'README quick start and walkthrough commands differ' >&2
        exit 1
    }
fi
