mod common;

use common::{TestResult, compare};
use rigforge_core::emit::{compact, pretty, reread, sorted};
use rigforge_core::error::{Error, Result};
use rigforge_core::json::{Value, parse_all, parse_one};
use rigforge_core::limits::CONFIG;
use rigforge_core::num::JqMode;
use rigforge_core::ops::{alt, j_text, jq_len, pick3, plus, raw_text, set_key};
use rigforge_core::text::cmd_subst;

const MODE: JqMode = JqMode::Literal;
const KEYS: [&str; 3] = ["change_id", "status", "reason"];

fn each(input: &[u8], f: fn(Value) -> Result<String>) -> Result<Vec<u8>> {
    let mut out = String::new();
    for doc in parse_all(input, &CONFIG)? {
        out.push_str(&f(doc)?);
    }
    Ok(out.into_bytes())
}

fn pair(input: &[u8], f: fn(Value, Value) -> Result<Value>) -> Result<Vec<u8>> {
    let mut docs = parse_all(input, &CONFIG)?.into_iter();
    let (Some(a), Some(b), None) = (docs.next(), docs.next(), docs.next()) else {
        return Err(Error::Multiple);
    };
    Ok(format!("{}\n", compact(&f(a, b)?, MODE)).into_bytes())
}

fn line(text: String) -> Result<String> {
    Ok(format!("{text}\n"))
}

fn as_compact(v: Value) -> Result<String> {
    line(compact(&v, MODE))
}

fn as_pretty(v: Value) -> Result<String> {
    line(pretty(&v, MODE))
}

fn as_sorted(v: Value) -> Result<String> {
    line(pretty(&sorted(v), MODE))
}

fn as_raw(v: Value) -> Result<String> {
    Ok(raw_text(&v, MODE))
}

fn as_joined(v: Value) -> Result<String> {
    Ok(j_text(&v, MODE))
}

fn as_reread(v: Value) -> Result<String> {
    line(compact(&reread(v, MODE), MODE))
}

fn as_length(v: Value) -> Result<String> {
    line(compact(&jq_len(&v, MODE)?, MODE))
}

fn as_pick3(v: Value) -> Result<String> {
    line(compact(&pick3(&v, KEYS)?, MODE))
}

fn argjson(input: &[u8]) -> Result<Vec<u8>> {
    let one = parse_one(&cmd_subst(input), &CONFIG)?;
    Ok(format!("{}\n", compact(&one, MODE)).into_bytes())
}

fn add_alt(a: Value, b: Value) -> Result<Value> {
    Ok(alt(a, b))
}

fn add_key(a: Value, b: Value) -> Result<Value> {
    set_key(a, "k", b)
}

fn check<F>(name: &str, floor: (usize, usize), f: F) -> TestResult
where
    F: Fn(&[u8]) -> Result<Vec<u8>>,
{
    let (ok, bad) = compare(name, f)?;
    if ok < floor.0 || bad < floor.1 {
        return Err(format!(
            "{name}: only {ok} accepted and {bad} rejected rows"
        ));
    }
    Ok(())
}

#[test]
fn compact_matches_jq() -> TestResult {
    check("doc-compact", (90, 50), |i| each(i, as_compact))
}

#[test]
fn pretty_matches_jq() -> TestResult {
    check("doc-pretty", (90, 50), |i| each(i, as_pretty))
}

#[test]
fn key_sorted_matches_jq() -> TestResult {
    check("doc-sorted", (90, 50), |i| each(i, as_sorted))
}

#[test]
fn raw_output_matches_jq() -> TestResult {
    check("doc-r", (90, 50), |i| each(i, as_raw))
}

#[test]
fn joined_output_matches_jq() -> TestResult {
    check("doc-j", (90, 50), |i| each(i, as_joined))
}

#[test]
fn text_boundary_matches_tojson_fromjson() -> TestResult {
    check("doc-reread", (90, 50), |i| each(i, as_reread))
}

#[test]
fn argjson_rule_matches_jq() -> TestResult {
    check("doc-argjson", (80, 80), argjson)
}

#[test]
fn plus_matches_jq() -> TestResult {
    check("op-plus", (15, 8), |i| pair(i, plus))
}

#[test]
fn alternative_matches_jq() -> TestResult {
    check("op-alt", (20, 0), |i| pair(i, add_alt))
}

#[test]
fn set_key_matches_jq() -> TestResult {
    check("op-setkey", (10, 4), |i| pair(i, add_key))
}

#[test]
fn length_matches_jq() -> TestResult {
    check("op-length", (40, 2), |i| each(i, as_length))
}

#[test]
fn shorthand_object_matches_jq() -> TestResult {
    check("op-pick3", (6, 4), |i| each(i, as_pick3))
}
