mod common;

use common::{TestResult, ascii, load, run_jq, skip_line};
use rigforge_core::num::{JqMode, Num, double_text};

const FILES: [&str; 8] = [
    "num-print",
    "num-double",
    "num-reread",
    "num-div",
    "num-tonumber",
    "str-repair",
    "str-escape",
    "space-s",
];

const REJECTED_BY_18: [&[u8]; 5] = [
    b"nan1",
    b"NaN123",
    b"nan007",
    b"snan5",
    b"nan99999999999999999999999",
];

const REJECTED_BY_18_TONUMBER: [&[u8]; 14] = [
    b" 12",
    b"12 ",
    b"\t12",
    b"12\t",
    b"\n12",
    b"12\n",
    b"\r12",
    b"12\r",
    b"5\0",
    b"1\x002",
    b"\xef\xbb\xbf5",
    b" inf",
    b"nan ",
    b"  -1  ",
];

fn known_18(file: &str, input: &[u8]) -> bool {
    let number_file = file.starts_with("num-");
    (number_file && REJECTED_BY_18.contains(&input))
        || (file == "num-tonumber" && REJECTED_BY_18_TONUMBER.contains(&input))
}

fn live(var: &str) -> Option<String> {
    match std::env::var(var) {
        Ok(path) if !path.is_empty() => Some(path),
        _ => {
            skip_line(&format!(
                "SKIPPED: {var} is not set, the live-jq test did not run"
            ));
            None
        }
    }
}

#[test]
fn jq_1_8_differs_only_in_the_pinned_rows() -> TestResult {
    let Some(bin) = live("JQ18") else {
        return Ok(());
    };
    let mut pinned_seen = 0;
    for file in FILES {
        let golden = load(file)?;
        for row in &golden.rows {
            let (status, output) = run_jq(&bin, &golden.args, &row.input)?;
            if known_18(file, &row.input) {
                pinned_seen += 1;
                if status != 5 || !output.is_empty() {
                    return Err(format!(
                        "{file} [{}]: jq 1.8 no longer rejects it",
                        row.label
                    ));
                }
                if row.status == 5 {
                    return Err(format!(
                        "{file} [{}]: pinned row is not a 1.7 value",
                        row.label
                    ));
                }
            } else if status != row.status || output != row.output {
                return Err(format!(
                    "{file} [{}]: jq 1.8 gave status {status} {:?}, golden {} {:?}",
                    row.label,
                    String::from_utf8_lossy(&output),
                    row.status,
                    String::from_utf8_lossy(&row.output)
                ));
            }
        }
    }
    if pinned_seen != 4 * REJECTED_BY_18.len() + REJECTED_BY_18_TONUMBER.len() {
        return Err(format!(
            "pinned table is stale ({pinned_seen} rows matched)"
        ));
    }
    Ok(())
}

fn double_mode_expectation(file: &str, text: &str) -> Option<String> {
    match file {
        "num-print" => Num::literal(text).ok().map(|n| n.text(JqMode::Double)),
        "num-reread" => Num::literal(text)
            .ok()
            .map(|n| n.reread(JqMode::Double).text(JqMode::Double)),
        _ => None,
    }
}

#[test]
fn jq_1_6_prints_numbers_as_doubles() -> TestResult {
    let Some(bin) = live("JQ16") else {
        return Ok(());
    };
    let mut compared = 0;
    for file in ["num-print", "num-reread"] {
        let golden = load(file)?;
        for row in &golden.rows {
            let (status, output) = run_jq(&bin, &golden.args, &row.input)?;
            let text = ascii(&row.input)?;
            let Some(want) = double_mode_expectation(file, text) else {
                continue;
            };
            if status != 0 {
                continue;
            }
            compared += 1;
            if output != format!("{want}\n").into_bytes() {
                return Err(format!(
                    "{file} [{}]: jq 1.6 printed {:?}, Double mode gives {want:?}",
                    row.label,
                    String::from_utf8_lossy(&output)
                ));
            }
        }
    }
    let golden = load("num-div")?;
    for row in &golden.rows {
        let (status, output) = run_jq(&bin, &golden.args, &row.input)?;
        let (a, b) = ascii(&row.input)?.split_once(' ').ok_or("bad pair")?;
        let a = Num::literal(a).map_err(|e| e.to_string())?;
        let b = Num::literal(b).map_err(|e| e.to_string())?;
        if status == 0 && b.f64() != 0.0 {
            compared += 1;
            let want = double_text(a.f64() / b.f64());
            if output != format!("{want}\n").into_bytes() {
                return Err(format!("num-div [{}]: jq 1.6 differs", row.label));
            }
        }
    }
    if compared < 100 {
        return Err(format!("only {compared} rows compared"));
    }
    Ok(())
}
