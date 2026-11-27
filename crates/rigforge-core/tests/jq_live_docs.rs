#![cfg(unix)]

mod common;

use common::{TestResult, ascii, load, run_jq, run_jq_argjson, skip_line};
use rigforge_core::emit::compact;
use rigforge_core::json::parse_all;
use rigforge_core::limits::CONFIG;
use rigforge_core::num::{JqMode, Num};
use rigforge_core::text::cmd_subst;

#[rustfmt::skip]
const FILES: [&str; 12] = [
    "doc-compact",
    "doc-pretty",
    "doc-sorted",
    "doc-r",
    "doc-j",
    "doc-reread",
    "doc-argjson",
    "op-plus",
    "op-alt",
    "op-setkey",
    "op-length",
    "op-pick3",
];

#[rustfmt::skip]
const LENGTH_KEEPS_LITERAL_IN_18: [&[u8]; 9] = [
    b"-0.0",
    b"1.50",
    b"-1.50",
    b"1e1000",
    b"-1e1000",
    b"1e-1000",
    b"1e2",
    b"100000000000000000000",
    b"0.0000001",
];

const NAN_PAYLOAD_WORD: &[u8] = b"nan7";
const BRACKET_ALPHABET: &[u8] = b"[]{}\":a1";
const DEPTH_ROWS_MIN_LEN: usize = 500;

fn live(var: &str) -> Option<String> {
    match std::env::var(var) {
        Ok(path) if !path.is_empty() => Some(path),
        _ => {
            skip_line(&format!("SKIPPED: {var} is not set, the live-jq test did not run"));
            None
        }
    }
}

fn run(bin: &str, file: &str, args: &[String], input: &[u8]) -> Result<(i32, Vec<u8>), String> {
    if file == "doc-argjson" {
        run_jq_argjson(bin, &cmd_subst(input))
    } else {
        run_jq(bin, args, input)
    }
}

fn keeps_literal(input: &[u8]) -> bool {
    LENGTH_KEEPS_LITERAL_IN_18.contains(&input)
}

fn is_deep_row(input: &[u8]) -> bool {
    input.len() > DEPTH_ROWS_MIN_LEN && input.iter().all(|b| BRACKET_ALPHABET.contains(b))
}

fn length_literal(input: &[u8]) -> Result<Vec<u8>, String> {
    let text = ascii(input)?;
    let num = Num::literal(text.trim_start_matches('-')).map_err(|e| e.to_string())?;
    Ok(format!("{}\n", num.lit()).into_bytes())
}

#[test]
fn jq_1_8_differs_only_in_the_pinned_rows() -> TestResult {
    let Some(bin) = live("JQ18") else {
        return Ok(());
    };
    let (mut nan, mut deep, mut length) = (0, 0, 0);
    for file in FILES {
        let golden = load(file)?;
        for row in &golden.rows {
            let (status, output) = run(&bin, file, &golden.args, &row.input)?;
            let shown = format!("{file} [{}]", row.label);
            if file.starts_with("doc-") && row.input == NAN_PAYLOAD_WORD {
                nan += 1;
                if row.status != 0 || status == 0 {
                    return Err(format!("{shown}: jq 1.8 no longer rejects a nan payload"));
                }
            } else if file.starts_with("doc-") && row.status != 0 && is_deep_row(&row.input) {
                if status != 0 && row.input.len() < 10_000 {
                    return Err(format!("{shown}: jq 1.8 still stops below its depth limit"));
                }
                deep += usize::from(status == 0);
            } else if file == "op-length" && keeps_literal(&row.input) {
                length += 1;
                if status != 0 || output != length_literal(&row.input)? || row.output == output {
                    return Err(format!("{shown}: jq 1.8 length of a number changed again"));
                }
            } else if (status != 0) != (row.status != 0) || (status == 0 && output != row.output) {
                return Err(format!(
                    "{shown}: jq 1.8 gave status {status} {:?}, golden {} {:?}",
                    String::from_utf8_lossy(&output),
                    row.status,
                    String::from_utf8_lossy(&row.output)
                ));
            }
        }
    }
    let pinned = (nan, deep, length);
    if pinned != (7, 10, LENGTH_KEEPS_LITERAL_IN_18.len()) {
        return Err(format!("pinned table is stale: {pinned:?}"));
    }
    Ok(())
}

#[test]
fn jq_1_6_prints_document_numbers_as_doubles() -> TestResult {
    let Some(bin) = live("JQ16") else {
        return Ok(());
    };
    let golden = load("num-print")?;
    let (mut compared, mut skipped) = (0, 0);
    for row in &golden.rows {
        let Ok(text) = ascii(&row.input) else {
            continue;
        };
        let doc = format!("[{text}]\n").into_bytes();
        let (status, output) = run_jq(&bin, &["-c".to_string(), ".".to_string()], &doc)?;
        let ours = parse_all(&doc, &CONFIG)
            .ok()
            .and_then(|docs| docs.first().map(|v| compact(v, JqMode::Double)));
        match (status, ours) {
            (0, Some(got)) => {
                compared += 1;
                if output != format!("{got}\n").into_bytes() {
                    return Err(format!(
                        "[{text}]: jq 1.6 printed {:?}, Double mode gives {got:?}",
                        String::from_utf8_lossy(&output)
                    ));
                }
            }
            _ => skipped += 1,
        }
    }
    if compared < 100 {
        return Err(format!("only {compared} rows compared, {skipped} skipped"));
    }
    Ok(())
}
