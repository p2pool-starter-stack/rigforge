{api: ["id", "worker-id"],
 cpu: ["enabled", "huge-pages", "huge-pages-jit", "hw-aes", "priority", "memory-pool", "yield", "max-threads-hint", "asm", "argon2-impl", "astrobwt-max-size", "astrobwt-avx2", "argon2", "astrobwt", "cn", "cn-heavy", "cn-lite", "cn-pico", "rx", "rx/wow", "cn/0", "cn-lite/0", "rx/arq", "rx/keva", "*"],
 randomx: ["init", "init-avx2", "mode", "1gb-pages", "rdmsr", "wrmsr", "cache_qos", "numa", "scratchpad_prefetch_mode"],
 tls: ["enabled", "protocols", "cert", "cert_key", "ciphers", "ciphersuites", "dhparam"],
 dns: ["ip_version", "ttl"]} as $sections |
["autosave", "background", "colors", "title", "log-file", "print-time", "health-print-time", "dmi", "retries", "retry-pause", "syslog", "user-agent", "verbose", "watch", "pause-on-battery", "pause-on-active", "dry-run"] as $keys |
to_entries[] | .key as $k |
if $sections | has($k) then
    if .value | type == "object" then
        .value | keys[] | select(. as $child | $sections[$k] | index($child) | not) | [$k, .] | tojson
    else empty end
elif $keys | index($k) | not then [$k] | tojson else empty end
