mod common;

use common::{TestResult, ascii, load};
use rigforge_core::num::{Num, double_text};

fn expect(row: &common::Row, name: &str, got: Option<String>) -> TestResult {
    let label = &row.label;
    match got {
        Some(text) => {
            let want = format!("{text}\n").into_bytes();
            if row.status != 0 || row.output != want {
                return Err(format!(
                    "{name} [{label}]: got {text:?}, jq status {} output {:?}",
                    row.status,
                    String::from_utf8_lossy(&row.output)
                ));
            }
        }
        None => {
            if row.status == 0 || !row.output.is_empty() {
                return Err(format!(
                    "{name} [{label}]: rejected, but jq printed a value"
                ));
            }
        }
    }
    Ok(())
}

fn each(name: &str, f: impl Fn(&str) -> Option<String>) -> TestResult {
    let golden = load(name)?;
    if golden.rows.is_empty() {
        return Err(format!("{name}: no rows"));
    }
    for row in &golden.rows {
        let got = match std::str::from_utf8(&row.input) {
            Ok(text) => f(text),
            Err(_) => None,
        };
        expect(row, name, got)?;
    }
    Ok(())
}

fn literal(text: &str) -> Option<Num> {
    Num::literal(text).ok()
}

#[test]
fn print_matches_jq() -> TestResult {
    each("num-print", |t| literal(t).map(|n| n.lit().to_string()))
}

#[test]
fn computed_double_matches_jq() -> TestResult {
    each("num-double", |t| {
        literal(t).map(|n| double_text(n.f64() * 1.0))
    })
}

#[test]
fn reread_matches_jq() -> TestResult {
    each("num-reread", |t| {
        literal(t).map(|n| {
            let first = Num::computed(n.f64() * 1.0);
            let again = first.reread(rigforge_core::num::JqMode::Literal);
            again.lit().to_string()
        })
    })
}

#[test]
fn division_matches_jq() -> TestResult {
    let golden = load("num-div")?;
    for row in &golden.rows {
        let text = ascii(&row.input)?;
        let (a, b) = text.split_once(' ').ok_or("bad pair")?;
        let a = Num::literal(a).map_err(|e| e.to_string())?;
        let b = Num::literal(b).map_err(|e| e.to_string())?;
        let got = if b.f64() == 0.0 {
            None
        } else {
            Some(double_text(a.f64() / b.f64()))
        };
        expect(row, "num-div", got)?;
    }
    Ok(())
}

#[test]
fn tonumber_matches_jq() -> TestResult {
    each("num-tonumber", |t| {
        Num::tonumber(t).ok().map(|n| n.lit().to_string())
    })
}

#[test]
fn tonumber_rows_with_invalid_utf8_are_rejected_by_jq() -> TestResult {
    let golden = load("num-tonumber")?;
    let mut seen = 0;
    for row in &golden.rows {
        if std::str::from_utf8(&row.input).is_err() {
            seen += 1;
            if row.status == 0 {
                return Err(format!("jq accepted invalid UTF-8 [{}]", row.label));
            }
        }
    }
    if seen == 0 {
        return Err("no invalid UTF-8 row".to_string());
    }
    Ok(())
}

#[test]
fn ties_match_jq() -> TestResult {
    each("num-tie-double", |t| {
        literal(t).map(|n| double_text(n.f64() * 1.0))
    })?;
    each("num-tie-length", |t| {
        literal(t).map(|n| double_text(n.f64().abs()))
    })
}

#[test]
fn tonumber_cuts_the_whole_text_at_the_first_nul() -> TestResult {
    each("num-nul", |t| {
        Num::tonumber(t).ok().map(|n| n.lit().to_string())
    })
}
