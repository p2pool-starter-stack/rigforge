# shellcheck shell=bash
# shellcheck disable=SC2154

. "$ROOT/scripts/goldens-ties.sh"

pairs_plus() {
    cat <<'DOCS'
{"a":1} {"b":2}
{"b":1,"a":2} {"a":9,"z":0}
{} {}
{"a":1} {}
{} {"a":1}
null {"a":1}
{"a":1} null
null null
{"a":1.0} {"a":1e2}
{"a":1} {"a":null}
{"rigforge":{"x":1},"y":2} {"generated_at":"t","rigforge":{"y":2}}
{"a":1} []
[] {"a":1}
{"a":1} 1
1 {"a":1}
{"a":1} "x"
"x" {"a":1}
{"a":1} true
true {"a":1}
false {"a":1}
[1] {"a":1}
{"a":1} nan
nan {"a":1}
null []
[] null
null 1
{"b":1,"a":2,"b":3} {"c":1,"b":9}
DOCS
    printf '%s %s\n' "$(many 20)" '{"k5":"new","zz":1,"k1":"first"}'
    printf '%s %s\n' "$(many 40)" '{"k40":"x","k41":2,"k2":[]}'
}

pairs_alt() {
    cat <<'DOCS'
null 1
false 1
true 1
0 1
0.0 1
"" 1
[] 1
{} 1
[false] 1
nan 1
NaN 1
-nan 1
Infinity 2
1.0 2
1e1000 2
-0 1
null null
false false
null false
false null
"x" "y"
null 1.0
false 1e2
null Infinity
null nan
null {"a":1.0}
DOCS
}

pairs_setkey() {
    cat <<'DOCS'
{} 1
{"k":1} 2
{"a":1,"k":2,"b":3} "x"
null 1
null null
{} null
[] 1
"s" 1
1 1
true 1
false 1
{"a":1} {"k":2}
{"k":null} 1.0
{"k":1} nan
{"a":1} Infinity
{"b":1,"a":2} [1e2]
DOCS
    printf '%s %s\n' "$(many 40 | sed 's/"k3":"again",//; s/,"k41":1.0//')" '"v"'
    printf '%s %s\n' "$(many 20)" '"v"'
}

docs_length() {
    cat <<'DOCS'
null
true
false
0
-3
5.5
-0
-0.0
1.50
-1.50
1e1000
-1e1000
1e-1000
1e2
100000000000000000000
0.0000001
nan
Infinity
-Infinity
""
"héllo"
"😀"
"\ud83d\ude00"
"a\u0000b"
[]
[1,2,3]
{}
{"a":1,"b":2}
[[]]
1 2 3
DOCS
}

docs_pick3() {
    cat <<'DOCS'
null
{}
{"change_id":1,"status":"ok","reason":"r"}
{"reason":"r","extra":1,"change_id":1.0}
{"status":null}
{"change_id":{"a":1.0},"status":[1e2],"reason":false}
[]
[1]
"x"
1
true
false
{} null
{"change_id":0} []
DOCS
}

run_ops() {
    header op-plus -sc '.[0] + .[1]'
    pairs_plus | rows op-plus plain -sc '.[0] + .[1]'
    header op-alt -sc '.[0] // .[1]'
    pairs_alt | rows op-alt plain -sc '.[0] // .[1]'
    header op-setkey -sc '.[1] as $v | .[0] | .k = $v'
    pairs_setkey | rows op-setkey plain -sc '.[1] as $v | .[0] | .k = $v'
    header op-length -c length
    docs_length | rows op-length plain -c length
    docs_bytes | rows op-length bytes -c length
    header op-pick3 -c '{change_id, status, reason}'
    docs_pick3 | rows op-pick3 plain -c '{change_id, status, reason}'
    run_ties
}
