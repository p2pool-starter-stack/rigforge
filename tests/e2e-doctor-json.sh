#!/usr/bin/env bash

e2e_doctor_json() {
    local report rc
    if report=$("$RIGFORGE" doctor --json 2>/dev/null); then rc=0; else rc=$?; fi

    if printf '%s\n' "$report" | jq -se '
        length == 1 and (.[0] |
            type == "object" and
            (keys == ["checks", "exit", "summary", "version"]) and
            ((.version | type) == "string" and (.version | length) > 0) and
            ((.exit | type) == "number" and .exit >= 0 and (.exit | floor) == .exit) and
            ((.summary | keys) == ["fail", "info", "ok", "warn"]) and
            all(.summary[]; type == "number" and . >= 0 and floor == .) and
            ((.checks | type) == "array") and
            all(.checks[];
                (keys == ["id", "message", "status"]) and
                ((.id | type) == "string" and (.id | length) > 0) and
                ((.status | type) == "string" and (.status as $status | ["ok", "warn", "fail", "info"] | index($status)) != null) and
                ((.message | type) == "string")))
    ' >/dev/null 2>&1; then
        ok "doctor JSON: one schema-valid report"
    else
        bad "doctor JSON: expected one schema-valid report" || true
        return 0
    fi

    if printf '%s' "$report" | jq -e --argjson rc "$rc" '.exit == $rc' >/dev/null 2>&1; then
        ok "doctor JSON: reported exit matches process status"
    else
        bad "doctor JSON: reported exit differs from process status" || true
    fi
    if printf '%s' "$report" | jq -e '
        .summary == {
            ok: ([.checks[] | select(.status == "ok")] | length),
            warn: ([.checks[] | select(.status == "warn")] | length),
            fail: ([.checks[] | select(.status == "fail")] | length),
            info: ([.checks[] | select(.status == "info")] | length)
        } and .summary.fail == 0
    ' >/dev/null 2>&1; then
        ok "doctor JSON: summary matches check rows"
    else
        bad "doctor JSON: summary does not match check rows" || true
    fi
    if printf '%s' "$report" | jq -e 'any(.checks[]; .id == "service" and .status == "ok")' >/dev/null 2>&1; then
        ok "doctor JSON: service check is live"
    else
        bad "doctor JSON: service check is not live" || true
    fi
    if printf '%s' "$report" | jq -e 'any(.checks[]; .id == "pool-connection" and .status == "ok")' >/dev/null 2>&1; then
        ok "doctor JSON: pool connection check is live"
    else
        bad "doctor JSON: pool connection check is not live" || true
    fi
}
