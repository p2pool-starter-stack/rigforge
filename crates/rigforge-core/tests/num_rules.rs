use rigforge_core::num::{JqMode, Num, dec_clean, double_text, is_nan_word, jq_mode};

fn lit(text: &str) -> String {
    Num::literal(text)
        .map(|n| n.lit().to_string())
        .unwrap_or_default()
}

#[test]
fn version_text_selects_the_mode() {
    let table = [
        ("jq-1.6", JqMode::Double),
        ("jq-1.6-159-gcff5336\n", JqMode::Double),
        ("jq-1.6rc1", JqMode::Double),
        ("jq-1.5", JqMode::Double),
        ("jq-1.7", JqMode::Literal),
        ("jq-1.7.1", JqMode::Literal),
        ("jq-1.8.2", JqMode::Literal),
        ("jq-1.60", JqMode::Literal),
        ("jq-2.0", JqMode::Literal),
        ("gojq 0.12.16", JqMode::Literal),
        ("", JqMode::Literal),
    ];
    for (text, want) in table {
        assert_eq!(jq_mode(text), want, "{text:?}");
    }
}

#[test]
fn literals_keep_their_text_by_the_decimal_rule() {
    let table = [
        ("1.0", "1.0"),
        ("1e2", "1E+2"),
        ("1e-05", "0.00001"),
        ("0E-5", "0.00000"),
        ("007", "7"),
        ("+1", "1"),
        ("1.", "1"),
        (".5", "0.5"),
        ("-0", "-0"),
        ("10e-1", "1.0"),
        ("0.0000001", "1E-7"),
        ("1e999", "1E+999"),
        ("10e999999999", "1.7976931348623157e+308"),
        ("1e-1147483647", "0E-1147483646"),
        ("999e-1147483648", "1.0E-1147483645"),
        ("Infinity", "1.7976931348623157e+308"),
        ("-inf", "-1.7976931348623157e+308"),
        ("nan", "null"),
    ];
    for (text, want) in table {
        assert_eq!(lit(text), want, "{text}");
    }
    for bad in ["", ".", "-", "1e", "1e+", "e5", "1_0", "0x10", "nan1x", "inf5", "--1"] {
        assert!(Num::literal(bad).is_err(), "{bad:?} must be rejected");
        assert!(dec_clean(bad).is_err(), "{bad:?} must be rejected");
    }
}

#[test]
fn nan_words() {
    for word in ["nan", "-NaN", "snan5", "nan007"] {
        assert!(is_nan_word(word), "{word}");
    }
    for word in ["nan1x", "inf", "", "n"] {
        assert!(!is_nan_word(word), "{word}");
    }
    assert!(Num::literal("nan").map(|n| n.is_nan()).unwrap_or(false));
}

#[test]
fn doubles_print_the_jq_way() {
    let table = [
        (1e15, "1000000000000000"),
        (1e16, "1e+16"),
        (1e17, "1e+17"),
        (0.0001, "0.0001"),
        (0.00001, "1e-05"),
        (123_456_789_012_345_680.0, "123456789012345680"),
        (-0.0, "-0"),
        (0.0, "0"),
        (1.5e-7, "1.5e-07"),
        (1e100, "1e+100"),
        (100.0, "100"),
        (0.1 + 0.2, "0.30000000000000004"),
        (f64::NAN, "null"),
        (f64::INFINITY, "1.7976931348623157e+308"),
        (f64::NEG_INFINITY, "-1.7976931348623157e+308"),
    ];
    for (f, want) in table {
        assert_eq!(double_text(f), want);
    }
}

#[test]
fn double_mode_prints_every_number_as_a_double() {
    let table = [("85.0", "85"), ("1e2", "100"), ("0.10", "0.1"), ("007", "7")];
    for (text, want) in table {
        let n = Num::literal(text).map_err(|e| e.to_string());
        assert_eq!(n.map(|n| n.text(JqMode::Double)), Ok(want.to_string()));
    }
    assert_eq!(
        Num::literal("85.0").map(|n| n.text(JqMode::Literal)),
        Ok("85.0".to_string())
    );
}

#[test]
fn computed_numbers_are_reread_as_literals() {
    let table = [
        (1e-5, "0.00001"),
        (1e17, "1E+17"),
        (100.0, "100"),
        (1.5e-7, "1.5E-7"),
        (f64::INFINITY, "1.7976931348623157E+308"),
        (f64::NAN, "null"),
    ];
    for (f, want) in table {
        assert_eq!(Num::computed(f).reread(JqMode::Literal).lit(), want);
    }
    let reread = Num::computed(1e-5).reread(JqMode::Double);
    assert_eq!(reread.text(JqMode::Double), "1e-05");
}

#[test]
fn plain_integers_print_the_same_in_every_mode() {
    for (text, want) in [
        ("85", true),
        ("007", true),
        ("-0", true),
        ("85.0", false),
        ("1e2", false),
        ("123456789012345678", false),
        ("nan", false),
    ] {
        assert_eq!(
            Num::literal(text).map(|n| n.is_plain_int()),
            Ok(want),
            "{text}"
        );
    }
}

#[test]
fn tonumber_follows_the_jq_json_reader() {
    let ok = [
        (" 12\n", "12"),
        ("\u{FEFF}5", "5"),
        ("5\0", "5"),
        ("1\u{0}2", "1"),
        ("5 \0 7", "5"),
        ("\r-1.50\t", "-1.50"),
    ];
    for (text, want) in ok {
        let got = Num::tonumber(text).map(|n| n.lit().to_string());
        assert_eq!(got, Ok(want.to_string()), "{text:?}");
    }
    let bad_inputs = [
        "",
        " ",
        "1 2",
        "\u{FEFF}\u{FEFF}5",
        " \u{FEFF}5",
        "\u{0}5",
        "\u{b}1",
        "\u{a0}1",
        "[1]",
    ];
    for bad in bad_inputs {
        assert!(Num::tonumber(bad).is_err(), "{bad:?}");
    }
}

#[test]
fn double_mode_rounds_the_full_text_once() {
    let table = [
        (
            "12345678901234567890123456789012345678901234567890",
            "1.2345678901234567e+49",
        ),
        (
            "1.00000000000000011102230246251565404236316680908203126",
            "1.0000000000000002",
        ),
    ];
    for (text, want) in table {
        let num = Num::literal(text).map(|n| n.text(JqMode::Double));
        assert_eq!(num.as_deref(), Ok(want));
    }
}
