use rigforge_core::text::{
    bash_i64, chars_prefix, cmd_subst, is_c_space, jq_utf8, strip_nul, trim_nl,
};

#[test]
fn command_substitution_drops_nul_then_all_trailing_newlines() {
    assert_eq!(cmd_subst(b"a\n\0\n"), b"a");
    assert_eq!(cmd_subst(b"a\0\n\n"), b"a");
    assert_eq!(cmd_subst(b"\n\n"), b"");
    assert_eq!(cmd_subst(b"a\r\n"), b"a\r");
    assert_eq!(cmd_subst(b"a\nb\n"), b"a\nb");
    assert_eq!(cmd_subst(b""), b"");
}

#[test]
fn trim_and_strip_helpers() {
    assert_eq!(trim_nl(b"x\n\n\n"), b"x");
    assert_eq!(trim_nl(b"\nx"), b"\nx");
    assert_eq!(strip_nul(b"\0a\0b\0"), b"ab");
}

#[test]
fn prefix_counts_bytes_in_c_and_glibc_characters_in_utf8() {
    let cases: [(&[u8], usize, &[u8]); 11] = [
        (b"\xed\xa0\x80b", 1, b"\xed"),
        (b"\xed\xa0\x80b", 2, b"\xed\xa0"),
        (b"\xf4\x90\x80\x80b", 1, b"\xf4\x90\x80\x80"),
        (b"\xf0\x9f\x98\x80b", 2, b"\xf0\x9f\x98\x80b"),
        (b"\xf8\x88\x80\x80\x80b", 1, b"\xf8\x88\x80\x80\x80"),
        (b"\xfc\x84\x80\x80\x80\x80b", 1, b"\xfc\x84\x80\x80\x80\x80"),
        (b"\xef\xbf\xbfb", 1, b"\xef\xbf\xbf"),
        (b"\xe2\x82", 1, b"\xe2"),
        (b"\xc0\xafb", 1, b"\xc0"),
        (b"\xc3\x28b", 2, b"\xc3("),
        (b"abc", 9, b"abc"),
    ];
    for (input, n, want) in cases {
        assert_eq!(chars_prefix(input, n, true), want, "{input:02x?} {n}");
    }
    assert_eq!(chars_prefix(b"\xc3\xa9\xc3\xa9", 3, false), b"\xc3\xa9\xc3");
    assert_eq!(chars_prefix(b"abc", 0, true), b"");
}

#[test]
fn bash_arithmetic_on_text() {
    let table: [(&str, Option<i64>); 23] = [
        ("", Some(0)),
        (" 7 ", Some(7)),
        ("010", Some(8)),
        ("08", None),
        ("0x1F", Some(31)),
        ("0x", Some(0)),
        ("-010", Some(-8)),
        ("+7", Some(7)),
        ("99999999999999999999", Some(7_766_279_631_452_241_919)),
        ("0xFFFFFFFFFFFFFFFF", Some(-1)),
        ("9223372036854775808", Some(i64::MIN)),
        ("-9223372036854775808", Some(i64::MIN)),
        ("1 2", None),
        ("00", Some(0)),
        ("-0", Some(0)),
        ("07", Some(7)),
        ("\t5\t", Some(5)),
        ("1.5", None),
        ("-", None),
        ("1a", None),
        ("0xg", None),
        ("0xFFFFFFFFFFFFFFFFFF", Some(-1)),
        ("18446744073709551616", Some(0)),
    ];
    for (text, want) in table {
        assert_eq!(bash_i64(text), want, "{text:?}");
    }
}

#[test]
fn c_space_is_the_posix_space_class() {
    for byte in 0..=255u8 {
        let want = matches!(byte, 9 | 10 | 11 | 12 | 13 | 32);
        assert_eq!(is_c_space(byte), want, "{byte:#04x}");
    }
}

#[test]
fn repair_keeps_valid_text_and_replaces_each_bad_sequence_once() {
    assert_eq!(
        jq_utf8("h\u{e9}llo \u{1F600}".as_bytes()),
        "h\u{e9}llo \u{1F600}"
    );
    assert_eq!(jq_utf8(b"\xed\xa0\x80"), "\u{FFFD}");
    assert_eq!(jq_utf8(b"\xe2\x28A"), "\u{FFFD}(A");
    assert_eq!(jq_utf8(b"\xff\xff"), "\u{FFFD}\u{FFFD}");
}
