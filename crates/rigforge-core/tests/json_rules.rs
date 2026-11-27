mod common;

use common::{TestResult, doc, lit, nested};
use rigforge_core::emit::compact;
use rigforge_core::error::Error;
use rigforge_core::json::{Value, parse_all, parse_one};
use rigforge_core::limits::{CONFIG, FILE, JsonLimits};
use rigforge_core::num::JqMode::Literal;

const GOOD: &str = r#"[1][2]
{}{}
"a""b"
1"a"
[1]2
true false
[ 1 , 2 ]"#;

const BAD: &str = r#"[1,]
[,1]
[1 2]
{"a" 1}
{"a":1,}
{1:2}
{"a"}
{"a":}
[
]
}
,
:
1,2
"a":1
nul
nullx
tru
truefalse
true1
1true
'a'
[1]]
{"a":1}x
[1}
{"a":[}"#;

const BAD_ESCAPES: &str = r#""\ud83d"
"\ud83dx"
"\ud83d\u0041"
"\ud83d\ud83d"
"\ud83dxxdc00"
"\ud83d\\ude00"
"\u12"
"\u12G4"
"\x"
"abc"#;

#[rustfmt::skip]
const BAD_RAW: [&str; 5] = ["\"\t\"", "\"\u{1}\"", "\u{b}1", "[\u{c}1]", "\u{a0}1"];

fn err(text: &[u8], limits: &JsonLimits) -> Option<Error> {
    parse_all(text, limits).err()
}

fn on_big_stack(f: impl FnOnce() -> TestResult + Send + 'static) -> TestResult {
    let builder = std::thread::Builder::new().stack_size(16 * 1024 * 1024);
    let handle = builder.spawn(f).map_err(|e| e.to_string())?;
    handle.join().map_err(|_| "thread panicked".to_string())?
}

#[test]
fn exactly_one_document_for_argjson() {
    assert_eq!(parse_one(b"", &CONFIG), Err(Error::Empty));
    assert_eq!(parse_one(b"  \n", &CONFIG), Err(Error::Empty));
    assert_eq!(parse_one(b"1 2", &CONFIG), Err(Error::Multiple));
    assert!(parse_one(b" {} ", &CONFIG).is_ok());
    assert_eq!(parse_all(b"1 2 3", &CONFIG).map(|d| d.len()), Ok(3));
    assert_eq!(parse_all(b"", &CONFIG).map(|d| d.len()), Ok(0));
}

#[test]
fn bom_is_stripped_once_and_checked_by_prefix() {
    let twice: &[u8] = b"\xef\xbb\xbf\xef\xbb\xbf1";
    assert_eq!(lit("\u{FEFF}[1]").as_deref(), Ok("[1]"));
    assert_eq!(err(twice, &CONFIG), Some(Error::Number));
    assert_eq!(parse_all(b"\xef\xbb", &CONFIG).map(|d| d.len()), Ok(0));
    assert_eq!(parse_all(b"\xef", &CONFIG).map(|d| d.len()), Ok(0));
    assert_eq!(err(b"\xef\xbb1", &CONFIG), Some(Error::Syntax));
    assert_eq!(err(b"\xbb\xbf1", &CONFIG), Some(Error::Number));
}

#[test]
fn depth_is_counted_like_jq_and_checked_before_recursing() {
    for (limits, cap) in [(CONFIG, 256), (FILE, 64)] {
        let at_cap = nested("[", "]", cap);
        let over = nested("[", "]", cap + 1);
        assert!(parse_one(at_cap.as_bytes(), &limits).is_ok());
        assert_eq!(err(over.as_bytes(), &limits), Some(Error::Depth));
        let fits = format!("{{\"a\":{}}}", nested("[", "]", cap - 2));
        let full = format!("{{\"a\":{}}}", nested("[", "]", cap - 1));
        assert!(parse_one(fits.as_bytes(), &limits).is_ok());
        assert_eq!(err(full.as_bytes(), &limits), Some(Error::Depth));
    }
}

#[test]
fn a_deep_run_is_stopped_at_the_cap_without_recursing() -> TestResult {
    on_big_stack(|| {
        for levels in [10_000usize, 100_000] {
            let arrays = "[".repeat(levels);
            let objects = "{\"a\":".repeat(levels);
            if err(arrays.as_bytes(), &CONFIG) != Some(Error::Depth) {
                return Err("deep arrays were not stopped".to_string());
            }
            if err(objects.as_bytes(), &CONFIG) != Some(Error::Depth) {
                return Err("deep objects were not stopped".to_string());
            }
        }
        Ok(())
    })
}

#[test]
fn node_and_byte_caps_are_enforced() {
    let tiny = JsonLimits {
        bytes: 8,
        depth: 8,
        nodes: 3,
    };
    let roomy = JsonLimits {
        bytes: 16,
        nodes: 6,
        ..tiny
    };
    let edge = JsonLimits {
        bytes: 7,
        depth: 8,
        nodes: 8,
    };
    assert!(parse_one(b"[1,2,3]", &edge).is_ok());
    assert_eq!(err(b"[1,2,3 ]", &edge), Some(Error::Size));
    assert!(parse_one(b"[1,2]", &tiny).is_ok());
    assert_eq!(err(b"[1,2,3]", &tiny), Some(Error::Nodes));
    assert_eq!(err(b"[1,2,3,4]", &tiny), Some(Error::Size));
    assert_eq!(err(b"{\"a\":[1],\"b\":2}", &tiny), Some(Error::Size));
    assert_eq!(parse_all(b"[1,2] [3,4]", &roomy).map(|d| d.len()), Ok(2));
    assert_eq!(err(b"[1,2] [3,4,5]", &roomy), Some(Error::Nodes));
}

#[test]
fn duplicate_keys_keep_the_first_position_and_the_last_value() -> TestResult {
    assert_eq!(lit(r#"{"a":1,"b":2,"a":3}"#)?, r#"{"a":3,"b":2}"#);
    assert_eq!(lit(r#"{"\u0061":1,"a":2}"#)?, r#"{"a":2}"#);
    let mut text = String::from("{");
    for n in 0..40 {
        text.push_str(&format!("\"k{n}\":{n},"));
    }
    text.push_str("\"k3\":\"x\",\"k39\":\"y\",\"k40\":0}");
    let value = doc(&text)?;
    let at = |n: usize| value.members().get(n).map(|(k, _)| k.as_str());
    assert_eq!(value.members().len(), 41);
    assert_eq!(value.get("k3"), Some(&doc("\"x\"")?));
    assert_eq!(value.get("k39"), Some(&doc("\"y\"")?));
    assert_eq!(at(3), Some("k3"));
    assert_eq!(at(39), Some("k39"));
    Ok(())
}

#[test]
fn string_escapes_follow_jq() -> TestResult {
    assert_eq!(lit(r#""\u00E9\u00e9""#)?, "\"éé\"");
    assert_eq!(lit(r#""\ud83d\ude00""#)?, "\"😀\"");
    assert_eq!(lit(r#""\ude00""#)?, "\"\u{FFFD}\"");
    assert_eq!(lit(r#""\u0000""#)?, "\"\\u0000\"");
    assert_eq!(lit("\"\u{7f}\"")?, "\"\\u007f\"");
    assert_eq!(lit(r#""\/\b\f\n\r\t\"\\""#)?, r#""/\b\f\n\r\t\"\\""#);
    for bad in BAD_ESCAPES.lines().chain(BAD_RAW) {
        assert!(doc(bad).is_err(), "{bad:?}");
    }
    Ok(())
}

#[test]
fn raw_bad_bytes_in_strings_are_repaired_like_jq() -> TestResult {
    let fffd = "\u{FFFD}";
    let cases: [(&[u8], String); 5] = [
        (b"\"\xed\xa0\x80\"", format!("\"{fffd}\"")),
        (b"\"\xf4\x90\x80\x80\"", format!("\"{fffd}\"")),
        (b"\"\xe2\x82\\u00e9\"", format!("\"{fffd}\u{e9}\"")),
        (b"\"a\xffb\"", format!("\"a{fffd}b\"")),
        (b"{\"k\xff\":1}", format!("{{\"k{fffd}\":1}}")),
    ];
    for (input, want) in cases {
        let value = parse_one(input, &CONFIG).map_err(|e| e.to_string())?;
        assert_eq!(compact(&value, Literal), want);
    }
    Ok(())
}

#[test]
fn grammar_accepts_and_rejects_like_jq() {
    for good in GOOD.lines() {
        assert!(parse_all(good.as_bytes(), &CONFIG).is_ok(), "{good}");
    }
    for bad in BAD.lines().chain(BAD_RAW) {
        assert!(parse_all(bad.as_bytes(), &CONFIG).is_err(), "{bad:?}");
    }
    assert_eq!(err(b"1e", &CONFIG), Some(Error::Number));
    assert_eq!(err(b"\xff", &CONFIG), Some(Error::Number));
    assert_eq!(err(b"nul", &CONFIG), Some(Error::Syntax));
}

#[test]
fn nan_stays_a_number_and_words_follow_jq() -> TestResult {
    let value = doc("[nan,NaN,-nan,Infinity,-Infinity,inf,nan7]")?;
    let Value::Arr(items) = &value else {
        return Err("not an array".to_string());
    };
    assert!(items.iter().all(|v| matches!(v, Value::Num(_))));
    assert!(matches!(items.first(), Some(Value::Num(n)) if n.is_nan()));
    let words = lit("[nan,Infinity,-Infinity,nan7]")?;
    let max = "1.7976931348623157e+308";
    assert_eq!(words, format!("[null,{max},-{max},null]"));
    Ok(())
}

#[test]
fn value_accessors_and_debug() -> TestResult {
    let value = doc(r#"{"a":1,"b":{"c":2}}"#)?;
    assert_eq!(value.get("a"), Some(&doc("1")?));
    assert_eq!(value.get("zz"), None);
    assert_eq!(value.members().len(), 2);
    assert_eq!(doc("[1]")?.get("a"), None);
    assert!(doc("[1]")?.members().is_empty());
    let shown = format!("{:?}", doc(r#"{"pass":"hunter2"}"#)?);
    assert!(!shown.contains("hunter2"));
    Ok(())
}

#[test]
fn raw_nul_bytes_are_rejected_where_jq_cuts_the_chunk() {
    for raw in [&b"{\"a\":1}\0\0\0"[..], b"{\"a\":1}\n\0", b"\0{\"a\":1}", b"1\0"] {
        assert!(parse_all(raw, &CONFIG).is_err(), "{raw:?}");
    }
}
