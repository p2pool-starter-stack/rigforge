mod common;

use std::time::{Duration, Instant};

use common::Rng;
use rigforge_core::emit::{compact, pretty, reread, sorted};
use rigforge_core::json::{Value, parse_all, parse_one};
use rigforge_core::limits::{CONFIG, JsonLimits};
use rigforge_core::num::JqMode::{self, Literal};
use rigforge_core::ops::{alt, j_text, jq_len};

const SMALL: JsonLimits = JsonLimits {
    bytes: 300,
    depth: 6,
    nodes: 40,
};

#[rustfmt::skip]
const PIECES: [&[u8]; 44] = [
    b"[", b"]", b"{", b"}", b",", b":", b"\"", b"\\", b"\\u", b"\\ud83d", b"\\ude00", b"\\u00e9", b" ",
    b"\n", b"\t", b"0", b"1", b"-", b"+", b".", b"e", b"E5", b"1.0", b"1e999", b"nan", b"NaN", b"Infinity",
    b"-inf", b"true", b"false", b"null", b"nul", b"\"k\"", b"\"a\":", b"{\"a\":", b"[[", b"]]", b"\xef\xbb\xbf",
    b"\xff", b"\xed\xa0\x80", b"\xf4\x90\x80\x80", b"\xe2\x82", b"\x00", b"\x7f",
];

#[rustfmt::skip]
const SEEDS: [&str; 12] = [
    r#"{"a":1.0,"b":[1e2,{"c":0.10}],"d":{},"e":"x\u00e9\ud83d\ude00"}"#,
    r#"[null,true,false,-0,0.5,1E+5,"\u0000\b\t\n\f\r\"\\/"]"#,
    r#"{"pools":[{"url":"u","pass":"p","tls-fingerprint":"f","daemon-poll-interval":1.0}],"DONATION":0}"#,
    r#"{"hashrate":{"total":[1234.50,null,0.0]},"a":NaN,"b":Infinity,"c":-Infinity}"#,
    r#"{"k0":0,"k1":1,"k2":2,"k3":3,"k4":4,"k5":5,"k6":6,"k7":7,"k8":8,"k9":9,"k10":10,"k11":11,"k12":12,"k13":13,"k14":14,"k15":15,"k16":16,"k17":17,"k3":"dup"}"#,
    r#"[[[[[[[[[[1]]]]]]]]]]"#,
    r#"{"a":{"b":{"c":{"d":{"e":[{"f":1}]}}}}}"#,
    "\"plain text\"",
    "12345678901234567890123456789012345678901234567890",
    "1 2 [3] {\"a\":4} \"five\"",
    "\u{FEFF}[1,2,3]",
    r#"{"":1,"\u007f":2,"</script>":3,"é":4}"#,
];

fn bytes(rng: &mut Rng) -> Vec<u8> {
    let mut out = Vec::new();
    let parts = rng.below(24);
    for _ in 0..parts {
        match rng.below(5) {
            0 => out.push(u8::try_from(rng.step() & 0xFF).unwrap_or(0)),
            1 => {
                let run = rng.below(400);
                let open = rng.pick(&[b'[', b'{']).copied().unwrap_or(b'[');
                out.extend(std::iter::repeat_n(open, run));
            }
            _ => out.extend_from_slice(rng.pick(&PIECES).copied().unwrap_or(b"")),
        }
    }
    out
}

#[rustfmt::skip]
const WORDS: [&[u8]; 14] = [
    b"null", b"true", b"false", b"0", b"-0", b"1.0", b"1e2", b"0.10", b"1e999", b"nan", b"Infinity", b"007",
    b"\"s\"", b"\"\\u00e9\\ud83d\\ude00\"",
];

#[rustfmt::skip]
const KEYS: [&[u8]; 4] = [b"\"a\"", b"\"b\"", b"\"\\u0061\"", b"\"\xc3\xa9\""];

fn document(rng: &mut Rng, depth: usize, out: &mut Vec<u8>) {
    let choices = if depth >= 5 { 1 } else { 3 };
    match rng.below(choices) {
        0 => out.extend_from_slice(rng.pick(&WORDS).copied().unwrap_or(b"null")),
        1 => {
            out.push(b'[');
            for at in 0..rng.below(5) {
                if at > 0 {
                    out.extend_from_slice(b" , ");
                }
                document(rng, depth + 1, out);
            }
            out.push(b']');
        }
        _ => {
            out.push(b'{');
            for at in 0..rng.below(5) {
                if at > 0 {
                    out.push(b',');
                }
                out.extend_from_slice(rng.pick(&KEYS).copied().unwrap_or(b"\"a\""));
                out.extend_from_slice(b": ");
                document(rng, depth + 1, out);
            }
            out.push(b'}');
        }
    }
}

fn mutate(rng: &mut Rng, seed: &[u8]) -> Vec<u8> {
    let mut doc = seed.to_vec();
    for _ in 0..rng.below(3) {
        let at = rng.below(doc.len().saturating_add(1)).min(doc.len());
        match rng.below(6) {
            0 => {
                if let Some(slot) = doc.get_mut(at) {
                    *slot = u8::try_from(rng.step() & 0xFF).unwrap_or(0);
                }
            }
            1 => {
                let piece = rng.pick(&PIECES).copied().unwrap_or(b"");
                doc.splice(at..at, piece.iter().copied());
            }
            2 => {
                let end = at.saturating_add(rng.below(8)).min(doc.len());
                doc.drain(at..end);
            }
            3 => {
                let end = at.saturating_add(rng.below(16)).min(doc.len());
                let copy: Vec<u8> = doc.get(at..end).unwrap_or(&[]).to_vec();
                doc.splice(at..at, copy);
            }
            4 => doc.truncate(at),
            _ => {
                let last = doc.len().saturating_sub(1);
                let other = rng.below(doc.len()).min(last);
                if !doc.is_empty() {
                    doc.swap(at.min(last), other);
                }
            }
        }
    }
    doc
}

fn parse_back(text: &str, mode: JqMode) -> Result<String, String> {
    let value = parse_one(text.as_bytes(), &CONFIG).map_err(|e| format!("{e}: {text:?}"))?;
    Ok(compact(&value, mode))
}

fn sorted_form(text: &str) -> Result<String, String> {
    let value = parse_one(text.as_bytes(), &CONFIG).map_err(|e| e.to_string())?;
    Ok(compact(&sorted(value), Literal))
}

fn check_value(value: &Value) -> Result<(), String> {
    let first = compact(value, Literal);
    let second = parse_back(&first, Literal)?;
    let third = parse_back(&second, Literal)?;
    if second != third {
        return Err(format!("print is not stable: {second:?} then {third:?}"));
    }
    let pretty_text = pretty(value, Literal);
    if parse_back(&pretty_text, Literal)? != second {
        return Err(format!("pretty and compact disagree for {first:?}"));
    }
    let sorted_text = compact(&sorted(value.clone()), Literal);
    if parse_back(&sorted_text, Literal)? != sorted_form(&second)? {
        return Err(format!("sorting is not stable for {first:?}"));
    }
    let again = parse_one(first.as_bytes(), &CONFIG).map_err(|e| e.to_string())?;
    if reread(value.clone(), Literal) != again {
        return Err(format!("reread differs from print and parse for {first:?}"));
    }
    let _ = j_text(value, Literal);
    let _ = jq_len(value, Literal);
    let _ = alt(value.clone(), Value::Null);
    Ok(())
}

fn exercise(input: &[u8], limits: &JsonLimits, started: Instant) -> Result<usize, String> {
    let docs = parse_all(input, limits);
    if started.elapsed() > Duration::from_secs(1) {
        return Err(format!(
            "one input took over a second: {} bytes",
            input.len()
        ));
    }
    let _ = parse_one(input, limits);
    let Ok(docs) = docs else {
        return Ok(0);
    };
    for value in &docs {
        check_value(value)?;
    }
    Ok(docs.len())
}

#[test]
fn twenty_thousand_byte_strings_give_a_value_or_a_typed_error() -> Result<(), String> {
    let began = Instant::now();
    let mut rng = Rng(0x9E37_79B9_7F4A_7C15);
    let mut accepted = 0;
    for round in 0..20_000 {
        let mut input = Vec::new();
        if round % 2 == 0 {
            document(&mut rng, 0, &mut input);
        } else {
            input = bytes(&mut rng);
        }
        let limits = if round % 4 == 0 { SMALL } else { CONFIG };
        accepted += exercise(&input, &limits, Instant::now())?;
    }
    if accepted < 5_000 {
        return Err(format!("only {accepted} documents were accepted"));
    }
    if began.elapsed() > Duration::from_secs(60) {
        return Err(format!("took {:?}", began.elapsed()));
    }
    Ok(())
}

#[test]
fn two_thousand_mutated_documents_give_a_value_or_a_typed_error() -> Result<(), String> {
    let began = Instant::now();
    let mut rng = Rng(0xD1B5_4A32_D192_ED03);
    let (mut accepted, mut rejected) = (0, 0);
    for round in 0..2_000 {
        let seed = SEEDS.get(round % SEEDS.len()).copied().unwrap_or("");
        let input = mutate(&mut rng, seed.as_bytes());
        match exercise(&input, &CONFIG, Instant::now())? {
            0 => rejected += 1,
            _ => accepted += 1,
        }
    }
    if accepted < 400 || rejected < 400 {
        return Err(format!(
            "mutations accepted {accepted} and rejected {rejected}"
        ));
    }
    if began.elapsed() > Duration::from_secs(60) {
        return Err(format!("took {:?}", began.elapsed()));
    }
    Ok(())
}

#[test]
fn every_seed_document_is_valid_before_mutation() -> Result<(), String> {
    for seed in SEEDS {
        let docs = parse_all(seed.as_bytes(), &CONFIG).map_err(|e| format!("{seed}: {e}"))?;
        if docs.is_empty() {
            return Err(format!("{seed}: no document"));
        }
    }
    Ok(())
}
