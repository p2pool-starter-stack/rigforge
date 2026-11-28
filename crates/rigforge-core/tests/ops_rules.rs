mod common;

use common::{TestResult, doc, lit};
use rigforge_core::emit::{compact, pretty};
use rigforge_core::error::Error;
use rigforge_core::json::Value;
use rigforge_core::num::JqMode::{Double, Literal};
use rigforge_core::ops::{alt, j_text, jq_len, pick3, plus, raw_text, set_key};

const WRONG: &str = "error: operator applied to a value of the wrong type";

fn show(value: Result<Value, Error>) -> String {
    match value {
        Ok(v) => compact(&v, Literal),
        Err(e) => format!("error: {e}"),
    }
}

fn wide_object() -> String {
    let mut text = String::from("{");
    for n in 0..30 {
        text.push_str(&format!("\"k{n}\":{n},"));
    }
    text.push_str("\"z\":0}");
    text
}

#[test]
fn plus_merges_in_place_and_appends() -> TestResult {
    let merged = plus(doc(r#"{"b":1,"a":2}"#)?, doc(r#"{"a":9,"z":0}"#)?);
    assert_eq!(show(merged), r#"{"b":1,"a":9,"z":0}"#);
    assert_eq!(show(plus(doc("null")?, doc("{\"a\":1}")?)), r#"{"a":1}"#);
    assert_eq!(show(plus(doc("{\"a\":1}")?, doc("null")?)), r#"{"a":1}"#);
    assert_eq!(show(plus(doc("null")?, doc("null")?)), "null");
    let extra = doc(r#"{"k5":"new","k29":"last","extra":1}"#)?;
    let text = show(plus(doc(&wide_object())?, extra));
    assert!(text.contains("\"k5\":\"new\",\"k6\":6"));
    assert!(text.ends_with("\"k29\":\"last\",\"z\":0,\"extra\":1}"));
    for bad in ["[]", "1", "\"x\"", "true", "false"] {
        assert_eq!(show(plus(doc(bad)?, doc("{}")?)), WRONG);
        assert_eq!(show(plus(doc("{}")?, doc(bad)?)), WRONG);
    }
    Ok(())
}

#[test]
fn set_key_replaces_in_place_appends_or_creates() -> TestResult {
    let new = || doc("[1]");
    let middle = set_key(doc(r#"{"a":1,"k":2,"b":3}"#)?, "k", new()?);
    assert_eq!(show(middle), r#"{"a":1,"k":[1],"b":3}"#);
    let append = set_key(doc(r#"{"a":1}"#)?, "k", new()?);
    assert_eq!(show(append), r#"{"a":1,"k":[1]}"#);
    assert_eq!(show(set_key(doc("null")?, "k", new()?)), r#"{"k":[1]}"#);
    for bad in ["[]", "1", "\"x\"", "true"] {
        assert_eq!(show(set_key(doc(bad)?, "k", new()?)), WRONG);
    }
    Ok(())
}

#[test]
fn alternative_treats_only_null_and_false_as_missing() -> TestResult {
    let right = || doc("\"r\"");
    let cases = [
        ("null", "\"r\""),
        ("false", "\"r\""),
        ("true", "true"),
        ("0", "0"),
        ("\"\"", "\"\""),
        ("[]", "[]"),
        ("{}", "{}"),
        ("nan", "null"),
        ("[false]", "[false]"),
    ];
    for (left, want) in cases {
        assert_eq!(compact(&alt(doc(left)?, right()?), Literal), want, "{left}");
    }
    Ok(())
}

#[test]
fn length_by_type() -> TestResult {
    let max = "1.7976931348623157e+308";
    let cases = [
        ("null", "0"),
        ("-3", "3"),
        ("5.5", "5.5"),
        ("1.50", "1.5"),
        ("1e1000", max),
        ("\"héllo\"", "5"),
        ("\"😀\"", "1"),
        ("[1,2,3]", "3"),
        ("{\"a\":1,\"b\":2}", "2"),
        ("[]", "0"),
        ("nan", "null"),
    ];
    for (input, want) in cases {
        assert_eq!(show(jq_len(&doc(input)?, Literal)), want, "{input}");
    }
    assert_eq!(show(jq_len(&doc("true")?, Literal)), WRONG);
    Ok(())
}

#[test]
fn length_of_a_long_number_follows_the_mode() -> TestResult {
    let input = doc("3.605094868786798082659083441015996404e-5")?;
    assert_eq!(show(jq_len(&input, Literal)), "3.6050948687867984e-05");
    assert_eq!(show(jq_len(&input, Double)), "3.605094868786798e-05");
    Ok(())
}

#[test]
fn shorthand_object_of_three_keys() -> TestResult {
    let keys = ["change_id", "status", "reason"];
    let pick = |text: &str| -> Result<String, String> { Ok(show(pick3(&doc(text)?, keys))) };
    let nulls = r#"{"change_id":null,"status":null,"reason":null}"#;
    let mixed = r#"{"change_id":1.0,"status":null,"reason":"r"}"#;
    assert_eq!(pick("null")?, nulls);
    assert_eq!(pick(r#"{"reason":"r","x":1,"change_id":1.0}"#)?, mixed);
    for bad in ["[]", "\"x\"", "1", "true", "false"] {
        assert_eq!(pick(bad)?, WRONG);
    }
    Ok(())
}

#[test]
fn raw_and_joined_text() -> TestResult {
    assert_eq!(j_text(&doc("\"a\\nb\\u0000\"")?, Literal), "a\nb\u{0}");
    assert_eq!(j_text(&doc("5.0")?, Literal), "5.0");
    assert_eq!(j_text(&doc("1e1")?, Literal), "1E+1");
    assert_eq!(j_text(&doc("null")?, Literal), "null");
    assert_eq!(j_text(&doc("false")?, Literal), "false");
    let nested = j_text(&doc("[1,{\"a\":[]}]")?, Literal);
    assert_eq!(nested, "[\n  1,\n  {\n    \"a\": []\n  }\n]");
    assert_eq!(raw_text(&doc("\"x\"")?, Literal), "x\n");
    let array = pretty(&doc("[1]")?, Literal);
    assert_eq!(raw_text(&doc("[1]")?, Literal), format!("{array}\n"));
    assert_eq!(lit("[1e2]")?, "[1E+2]");
    Ok(())
}
