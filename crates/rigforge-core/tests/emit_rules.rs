mod common;

use common::{TestResult, doc};
use rigforge_core::emit::{compact, escape_into, pretty, reread, sorted};
use rigforge_core::json::parse_one;
use rigforge_core::limits::CONFIG;
use rigforge_core::num::JqMode::{Double, Literal};

const NESTED: &str = r#"{"a":1,"b":[1,2,{"c":[]}],"d":{},"e":"x"}"#;

const NESTED_PRETTY: &str = r#"{
  "a": 1,
  "b": [
    1,
    2,
    {
      "c": []
    }
  ],
  "d": {},
  "e": "x"
}"#;

#[rustfmt::skip]
const REREAD_TEXTS: [&str; 3] = [
    "[1e-5,1e2,1.0,0.10,-0,0E-5,1e999,Infinity,-Infinity,nan,[NaN],{\"a\":Infinity}]",
    "{\"a\":[1.50,{\"b\":1e17}],\"c\":\"x\",\"d\":null,\"e\":true}",
    "100000000000000000000",
];

fn escaped(text: &str) -> String {
    let mut out = String::new();
    escape_into(&mut out, text);
    out
}

#[test]
fn escape_classes() {
    assert_eq!(escaped("a"), "\"a\"");
    assert_eq!(escaped("\""), "\"\\\"\"");
    assert_eq!(escaped("\\"), "\"\\\\\"");
    assert_eq!(escaped("\u{8}\t\n\u{c}\r"), "\"\\b\\t\\n\\f\\r\"");
    assert_eq!(escaped("\u{0}\u{1}\u{b}"), "\"\\u0000\\u0001\\u000b\"");
    assert_eq!(escaped("\u{1b}\u{1f}"), "\"\\u001b\\u001f\"");
    assert_eq!(escaped("\u{7f}"), "\"\\u007f\"");
    assert_eq!(escaped("/<>&'"), "\"/<>&'\"");
    let raw = "\u{80}\u{9f}\u{a0}\u{2028}\u{feff}\u{ffff}é😀";
    assert_eq!(escaped(raw), format!("\"{raw}\""));
}

#[test]
fn compact_has_no_spaces_and_pretty_uses_two() -> TestResult {
    let value = doc(NESTED)?;
    assert_eq!(compact(&value, Literal), NESTED);
    assert_eq!(pretty(&value, Literal), NESTED_PRETTY);
    assert_eq!(pretty(&doc("[]")?, Literal), "[]");
    assert_eq!(pretty(&doc("{}")?, Literal), "{}");
    assert_eq!(pretty(&doc("[[]]")?, Literal), "[\n  []\n]");
    assert_eq!(pretty(&doc("\"é\"")?, Literal), "\"é\"");
    Ok(())
}

#[test]
fn numbers_print_by_mode() -> TestResult {
    let value = doc("[1.0,1e2,0.10,-0,1e-5]")?;
    assert_eq!(compact(&value, Literal), "[1.0,1E+2,0.10,-0,0.00001]");
    assert_eq!(compact(&value, Double), "[1,100,0.1,-0,1e-05]");
    Ok(())
}

#[test]
fn sorting_is_deep_by_utf8_bytes_and_keeps_arrays() -> TestResult {
    let keys = r#"{"z":0,"é":1,"Z":2,"😀":3,"\uffff":4}"#;
    let value = doc(&format!(r#"{{"b":1,"a":{keys},"B":[{{"y":1,"x":2}},3]}}"#))?;
    let want_keys = "{\"Z\":2,\"z\":0,\"é\":1,\"\u{ffff}\":4,\"😀\":3}";
    let want = format!("{{\"B\":[{{\"x\":2,\"y\":1}},3],\"a\":{want_keys},\"b\":1}}");
    assert_eq!(compact(&sorted(value), Literal), want);
    Ok(())
}

#[test]
fn reread_is_print_then_parse() -> TestResult {
    for text in REREAD_TEXTS {
        for mode in [Literal, Double] {
            let value = doc(text)?;
            let printed = compact(&value, mode);
            let again = parse_one(printed.as_bytes(), &CONFIG).map_err(|e| e.to_string())?;
            let got = compact(&reread(value, mode), mode);
            assert_eq!(got, compact(&again, mode), "{text}");
        }
    }
    let value = reread(doc("[Infinity,nan]")?, Literal);
    assert_eq!(compact(&value, Literal), "[1.7976931348623157E+308,null]");
    assert_eq!(value, doc("[1.7976931348623157E+308,null]")?);
    Ok(())
}
