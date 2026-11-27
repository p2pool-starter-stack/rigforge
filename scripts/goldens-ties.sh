# shellcheck shell=bash
# shellcheck disable=SC2154

pairs_ties() {
    cat <<'DOCS'
2194495613066652.25
241747018672653.125
2.98023223876953125e-8
2.93329274228972885
3.76332364733555715
2.93329274228972895
2.93329274228972885000
2.93329274228972885001
12345678901234567.5
DOCS
}

nul_numbers() {
    cat <<'DOCS'
5\x00\x202
5\n\x001
.15\t\x00
15\x00\r\x005
\xef\xbb\xbf5\x00\x202
\x205\x00
DOCS
}

run_ties() {
    header num-tie-double -c '. * 1'
    pairs_ties | rows num-tie-double plain -c '. * 1'
    header num-tie-length -c length
    pairs_ties | rows num-tie-length plain -c length
    header num-nul -Rsc tonumber
    nul_numbers | rows num-nul bytes -Rsc tonumber
}
