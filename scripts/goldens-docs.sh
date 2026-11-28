# shellcheck shell=bash
# shellcheck disable=SC2154

. "$ROOT/scripts/goldens-ops.sh"

deep() {
    printf '%*s' "$1" '' | tr ' ' "$2"
}

nested() {
    deep "$1" '['
    deep "$1" ']'
    echo
}

many() {
    local i
    printf '{'
    for i in $(seq 1 "$1"); do
        printf '"k%s":%s,' "$i" "$i"
    done
    printf '"k3":"again","k%s":1.0}\n' "$(($1 + 1))"
}

docs_plain() {
    cat <<'DOCS'
0
-0
0.0
-0.0
1.0
1.50
1e2
1E+2
1.0e2
1e-5
1e1000
1e-1000
0E-5
007
1.
.5
+1
100000000000000000000
12345678901234567890123456789012345678901234567890
nan
NaN
-nan
nan7
snan
nan1x
Infinity
-Infinity
inf
INFINITY
null
true
false
""
"a"
[]
{}
[[]]
[{}]
[1.0,2e0,[3.50]]
{"a":1.0,"b":[1e2,{"c":0.10}],"d":{}}
{"a":1,"b":2,"a":3}
{"a":1,"a":2}
{"b":1,"a":2,"B":3,"é":4,"\u00e9":5,"a\nb":6,"\u007f":7,"":8,"</script>":9,"😀":10,"\uffff":11,"a\"b":12}
{"pools":[{"url":"x","pass":"p","daemon-poll-interval":1.0}],"DONATION":0,"xmrig":{"z":1,"a":[1e1]}}
{"hashrate":{"total":[1234.50,null,0.0]},"a":NaN,"b":Infinity,"c":-Infinity,"d":1e999}
{ "a" : 1 , "b" : [ ] }
1 2
{"a":1}{"b":2}
[1][2]
"a""b"
1"a"
"a"1
[1]2
1[2]
true false
null null
[1,]
[,1]
[1 2]
{"a" 1}
{"a":1,}
{1:2}
{"a"}
{"a":}
[
]
{
}
,
:
1,2
"a":1
nul
nullx
tru
truefalse
true1
1true
'a'
{'a':1}
[1]]
{"a":1}}
[[]
[1] x
{"a":1} x
1 x
"\x"
"\u12"
"\u12G4"
"\ud800\u0041"
"\udc00\ud800"
"\ud800\ud800"
"\ud800"
"\ud800x"
"\udc00"
-
1-
--1
1e
a
"abc
abc"
[1}
{"a":1]
{"a":[}
0x1
1.5.5
1ee5
""
"\u0000"
"\u0001\u001f\u007f\u0080\u009f\u00a0"
"\b\t\n\f\r"
"\u2028\u2029\ufeff\ufffe\uffff"
"\"\\/<>&'"
"\/"
"é\u00e9\u00E9漢字😀\ud83d\ude00"
"\uD83D\uDE00"
"a\u0000b"
{"\u0001":1,"\"":2,"\u007f":3}
DOCS
    many 20
    many 40
    many 3
}

docs_bytes() {
    cat <<'DOCS'
"\x09"
"\x01"
"\x1f"
"\x7f"
"\xff"
"\xc0\xaf"
"\xc3\x28"
"\xe2\x82"
"\xed\xa0\x80"
"\xf4\x90\x80\x80"
"\xf0\x9f\x98"
"\xe2\x82\\u00e9"
"\xe2\x82\\ud83d\\ude00"
"a\xf0\x9f\x98\\u0041"
{"k\xff":1}
{"\xed\xa0\x80":1,"\xef\xbf\xbd":2}
\xef\xbb\xbf"x"
\xef\xbb\xbf[1]
\xef\xbb\xbf
[\xef\xbb\xbf1]
\xef\xbb\xbf\xef\xbb\xbf1
\xef\xbb
\xef
\xef\xbb1
\xbb\xbf1
[1]\n[2]\n
\n
\t\r\n 1 \r\n
[\x0b1]
[1\x0c]
\xc2\xa01
1\xc2\xa0
[1,\xc2\x85 2]
\xff
[\xff]
1\xff
\x20\x20[ 1 , 2 ]\x20\x20
DOCS
}

docs_deep() {
    local n
    for n in 63 64 65 255 256 257 1000 10000 10001; do
        nested "$n"
    done
    printf '{"a":%s1%s}\n' "$(deep 255 '[')" "$(deep 255 ']')"
    printf '{"a":%s1%s}\n' "$(deep 256 '[')" "$(deep 256 ']')"
}

docs_nul() {
    cat <<'DOCS'
1\x002
"a\x00b"
[1,\x002]
\x00
nu\x00ll
1 \x00 2
DOCS
}

argjson_rows() {
    local name=$1 mode=$2 line x status
    while IFS= read -r line; do
        if [ "$mode" = bytes ]; then
            printf '%b' "$line" >"$work/in"
        else
            printf '%s' "$line" >"$work/in"
        fi
        { x=$(cat "$work/in"); } 2>/dev/null
        status=0
        "$JQ" -nc --argjson x "$x" '$x' >"$work/out" 2>/dev/null || status=$?
        printf '%s\t%s\t%s\t%s\n' "$(hex <"$work/in")" "$status" "$(hex <"$work/out")" \
            "$(label "$work/in")" >>"$stage/$name.tsv"
    done
}

doc_file() {
    local name=$1
    shift
    header "$name" "$@"
    docs_plain | rows "$name" plain "$@"
    docs_bytes | rows "$name" bytes "$@"
}

run_docs() {
    doc_file doc-compact -c .
    docs_deep | rows doc-compact plain -c .
    doc_file doc-pretty .
    doc_file doc-sorted -S .
    doc_file doc-r -r .
    doc_file doc-j -j .
    doc_file doc-reread -c 'tojson | fromjson'

    header doc-argjson -nc --argjson x TEXT '$x'
    {
        docs_plain
        docs_deep
    } | argjson_rows doc-argjson plain
    {
        docs_bytes
        docs_nul
        printf '%s\n' '' '\n' '  ' 'null\n' '{"a":1}\n\n\n' '1\n2'
    } | argjson_rows doc-argjson bytes
    run_ops
}
