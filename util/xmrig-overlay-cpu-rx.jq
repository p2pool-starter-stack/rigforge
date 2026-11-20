def int: type == "number" and . == floor;
def core: int and . >= -1 and ($n == 0 or . < $n);
def mask: int and . >= -1 and (. < 0 or $n == 0 or $n > 52 or . < pow(2; $n));
(.cpu | if type == "object" and has("rx") then .rx else empty end) as $r |
if $r == false then empty
elif ($r | type) == "number" then (if ($r | int) and $r >= 1 then empty else "a number must be a positive integer" end)
elif ($r | type) == "array" then
    if ($r | length) == 0 then "an array needs at least one thread entry"
    else $r | to_entries[] | .key as $i | .value as $e |
        if ($e | core) or (($e | type) == "array" and ($e | length) == 2 and ($e[0] | int) and $e[0] >= 1 and ($e[1] | core)) then empty
        else "entry \($i) must be -1, a core index below \(if $n == 0 then "the host logical CPU count" else $n end), or an [intensity, affinity] pair" end
    end
elif ($r | type) == "object" then
    (if ($r | has("threads")) and (($r.threads | int | not) or $r.threads < 0) then "threads must be a non-negative integer" else empty end),
    (if ($r | has("affinity")) and (($r.affinity | mask) | not) then "affinity must be -1 or a core mask within the host logical CPUs" else empty end)
else "must be an array, an object, a positive integer or false" end
