#!/usr/bin/env bash
set -euo pipefail

JQ=${JQ:-jq}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
usage() {
    echo "usage: $0 jq" >&2
    exit 2
}

[ "${1:-}" = jq ] || usage
command -v "$JQ" >/dev/null 2>&1 || {
    echo "make-goldens: $JQ not found" >&2
    exit 1
}

version=$("$JQ" --version)
out=${OUT_DIR:-$ROOT/crates/rigforge-core/tests/golden/$version}
mkdir -p "$out"
work=$(mktemp -d)
stage=$work/stage
mkdir "$stage"
cleanup() {
    rm -f "$work/in" "$work/out" "$stage"/*
    rmdir "$stage" "$work"
}
trap cleanup EXIT
hex() { od -An -v -tx1 | tr -d ' \n'; }
label() { local t && t=$(LC_ALL=C tr -c '[:print:]' '?' <"$1" | cut -c1-60 | sed 's/ *$//') && printf '%s' "${t:--}"; }
header() {
    local name=$1
    shift
    (
        IFS=$'\t'
        printf '%s\n' "$*"
    ) >"$stage/$name.tsv"
}

rows() {
    local name=$1 mode=$2 line status
    shift 2
    while IFS= read -r line; do
        if [ "$mode" = bytes ]; then
            printf '%b' "$line" >"$work/in"
        else
            printf '%s' "$line" >"$work/in"
        fi
        status=0
        "$JQ" "$@" <"$work/in" >"$work/out" 2>/dev/null || status=$?
        printf '%s\t%s\t%s\t%s\n' "$(hex <"$work/in")" "$status" "$(hex <"$work/out")" \
            "$(label "$work/in")" >>"$stage/$name.tsv"
    done
}

numbers() {
    cat <<'EOF'
0
-0
0.0
-0.0
0.00
00
007
-007
00.5
0.5
.5
-.5
+.5
+1
+1.
1.
1.e5
1
-1
1.0
1.50
0.10
0.1
0.2
0.3
0.30000000000000004
1234.5
1234.50
10e-1
1.0e2
1e2
1E+2
1E2
1e02
1e+02
1e-02
1e-5
1e-05
1e-6
1e-7
0.000001
0.0000001
0.0000010
0.00001
0.0001
0.000123
0E-5
0e5
0e0
0E-9
0e-7
1e15
1e16
1e17
1e21
1e22
1e23
5e-324
100000000000000000000
123456789012345678
123456789012345680
9007199254740992
9007199254740993
12345678901234567890
12345678901234567890123456789012345678901234567890
1.5e-7
1e308
1.7976931348623157e308
1.8e308
4.9e-324
1e-324
2.4703282292062327e-324
2.4703282292062328e-324
1e999
1e-999
1e999999999
1.5e999999999
9.99e999999999
10e999999999
1e1000000000
-1e1000000000
1e4294967297
1e-4294967297
1e99999999999999999999
1e-99999999999999999999
1e9999999999999999999999999999999999999999
1e-9999999999999999999999999999999999999999
1e0000000000000000000000000005
0e999999999
0e1000000000
0e-1147483646
0e-1147483647
0e-5000000000
0.00e-1147483646
.0e-1147483640
1e-1000000000
1e-1147483646
1e-1147483647
5e-1147483647
6e-1147483647
50e-1147483648
51e-1147483648
15e-1147483648
25e-1147483647
25e-1147483648
123e-1147483646
123e-1147483647
123e-1147483648
123e-1147483649
999e-1147483648
999e-1147483649
0.5e-1147483646
-6e-1147483647
-4e-1147483647
nan
NaN
NAN
-nan
+nan
nan0
nan1
NaN123
nan007
snan
sNaN
SNAN
snan5
nan99999999999999999999999
nan1x
nanx
inf
Inf
INF
-inf
+inf
infinity
Infinity
-Infinity
+Infinity
INFINITY
infinit
infi
infinityx
inf5
.
-
+
e5
1e
1e+
1e-
.e5
1.2.3
1e5.5
0x10
1_0
--1
+-1
nulll
EOF
}

pairs() {
    local a b
    for a in 1234.5 1234.50 0 0.0 1e3 1e-7 1e20 1e300 1 2 3 7 100; do
        for b in 0.00 0.01 95.40 100.00 999999.99 3 7; do
            printf '%s %s\n' "$a" "$b"
        done
    done
}

header num-print -c .
numbers | rows num-print plain -c .

header num-double -c '. * 1'
numbers | rows num-double plain -c '. * 1'

header num-reread -c '(. * 1) | tojson | fromjson'
numbers | rows num-reread plain -c '(. * 1) | tojson | fromjson'

header num-div -sc '.[0] / .[1]'
pairs | rows num-div plain -sc '.[0] / .[1]'

header num-tonumber -Rsc tonumber
{
    numbers
    cat <<'EOF'
\x2012
12\x20
\t12
12\t
\n12
12\n
\r12
12\r
\x0b12
12\x0b
\x0c12
\xc2\xa012
12\xc2\xa0
5\x205
\x20
\t
\n

\x005
5\x00
1\x002
\xef\xbb\xbf5
\xef\xbb\xbf\xef\xbb\xbf5
5\xef\xbb\xbf
\x20\xef\xbb\xbf5
\x20inf
nan\x20
\x20\x20-1\x20\x20
[1]
"5"
1,2
\xff
EOF
} | rows num-tonumber bytes -Rsc tonumber

header str-repair -Rsj .
rows str-repair bytes -Rsj . <<'EOF'

abc
\xff
\xc0\xaf
\xc1\xbf
\xc3\x28
\xe2\x82
\xe2\x82\x28
\xe2\x28
\xe2\x28A
\xed\xa0\x80
\xf4\x90\x80\x80
\xe0\x80\x80
\xe0\x9f\xbf
\xf0\x80\x80\x80
\xed\xbf\xbf
\xed\xa0
\xe0\x80
\xf4\x90
\xf5\x80\x80\x80
\xf8\x88\x80\x80\x80
\xfe\xff
\xed\x9f\xbf
\xf4\x8f\xbf\xbf
\x80
\xbf\xbf
\xc2
\xc2\x80
\xdf\xbf
\xe0\xa0\x80
\xef\xbf\xbd
\xef\xbf\xbe\xef\xbf\xbf
\xf0\x90\x80\x80
\xf0\x9f\x98\x80
\xf0\x9f\x98
\xf0\x9f
\xf0
a\xffb
a\x00b
\x00
\xe2\x82\xac
\xe2\x82\xe2\x82\xac
\xf0\x9f\x98\xf0\x9f\x98\x80
\xc3\xc3\xa9
\x7f
\x01\x1f
\xc2\x80\xc2\x9f
\xc2\xa0
\xe2\x80\xa8
\xef\xbb\xbf
\xf0\x9f\x98\x80\xf0\x9f\x98
\xed\xa0\x80\xed\xb0\x80
EOF

header str-escape -c .
rows str-escape plain -c . <<'EOF'
""
"a"
"\u0000"
"\u0001"
"\u0008"
"\u0009"
"\u000a"
"\u000b"
"\u000c"
"\u000d"
"\u001b"
"\u001f"
"\b\t\n\f\r"
"\u007f"
"\u0080"
"\u009f"
"\u00a0"
"\u2028"
"\u2029"
"\ufeff"
"\ufffe"
"\uffff"
"\""
"\\"
"/"
"\/"
"<>&'"
"é"
"\u00e9"
"\u00E9"
"漢字"
"😀"
"\ud83d\ude00"
"\ud83d"
"\ud83dx"
"\ude00"
"\ude00x"
"a\u0000b"
{"\u0001":1,"\"":2,"\u007f":3}
{"b":1,"a":2,"b":3}
{"":1}
[]
{}
[[]]
[{}]
EOF
rows str-escape bytes -c . <<'EOF'
"\x09"
"\x01"
"\x7f"
"\xff"
"\xed\xa0\x80"
"\xf4\x90\x80\x80"
{"k\xff":1}
\xef\xbb\xbf"x"
"a\x00b"
EOF

header space-s -nc '[range(0; 1114112) | select(. < 55296 or . > 57343) | [.] | implode | select(test("\\S") | not) | explode[0]]'
rows space-s plain -nc '[range(0; 1114112) | select(. < 55296 or . > 57343) | [.] | implode | select(test("\\S") | not) | explode[0]]' <<<''

. "$ROOT/scripts/goldens-docs.sh"
run_docs
cp "$stage"/*.tsv "$out/"
