#![deny(clippy::arithmetic_side_effects)]

const REPLACEMENT: char = '\u{FFFD}';

fn lead_len(first: u8) -> usize {
    match first {
        0xC2..=0xDF => 2,
        0xE0..=0xEF => 3,
        0xF0..=0xF4 => 4,
        _ => 0,
    }
}

fn lead_bits(len: usize) -> u32 {
    match len {
        2 => 0x1F,
        3 => 0x0F,
        _ => 0x07,
    }
}

fn first_codepoint(len: usize) -> u32 {
    match len {
        2 => 0x80,
        3 => 0x800,
        _ => 0x1_0000,
    }
}

fn is_continuation(byte: u8) -> bool {
    byte & 0xC0 == 0x80
}

pub fn jq_utf8(input: &[u8]) -> String {
    let mut out = String::with_capacity(input.len());
    let mut rest = input;
    while let Some((&first, tail)) = rest.split_first() {
        if first < 0x80 {
            out.push(char::from(first));
            rest = tail;
            continue;
        }
        let want = lead_len(first);
        if want == 0 {
            out.push(REPLACEMENT);
            rest = tail;
            continue;
        }
        if rest.len() < want {
            out.push(REPLACEMENT);
            rest = &[];
            continue;
        }
        let mut cp = u32::from(first) & lead_bits(want);
        let mut used = want;
        let mut broken = false;
        for (index, &byte) in rest.iter().enumerate().take(want).skip(1) {
            if !is_continuation(byte) {
                used = index;
                broken = true;
                break;
            }
            cp = cp.wrapping_shl(6) | (u32::from(byte) & 0x3F);
        }
        let decoded = if broken || cp < first_codepoint(want) {
            None
        } else {
            char::from_u32(cp)
        };
        out.push(decoded.unwrap_or(REPLACEMENT));
        rest = rest.get(used..).unwrap_or(&[]);
    }
    out
}

pub fn strip_nul(input: &[u8]) -> Vec<u8> {
    input.iter().copied().filter(|&b| b != 0).collect()
}

pub fn trim_nl(input: &[u8]) -> &[u8] {
    let mut rest = input;
    while let Some((&last, head)) = rest.split_last() {
        if last != b'\n' {
            break;
        }
        rest = head;
    }
    rest
}

pub fn cmd_subst(input: &[u8]) -> Vec<u8> {
    trim_nl(&strip_nul(input)).to_vec()
}

fn libc_char_len(rest: &[u8]) -> usize {
    let Some(&first) = rest.first() else {
        return 0;
    };
    let (want, bits, floor): (usize, u32, u32) = match first {
        0xC2..=0xDF => (2, 0x1F, 0x80),
        0xE0..=0xEF => (3, 0x0F, 0x800),
        0xF0..=0xF7 => (4, 0x07, 0x1_0000),
        0xF8..=0xFB => (5, 0x03, 0x20_0000),
        0xFC..=0xFD => (6, 0x01, 0x400_0000),
        _ => return 1,
    };
    if rest.len() < want {
        return 1;
    }
    let mut cp = u32::from(first) & bits;
    for &byte in rest.iter().take(want).skip(1) {
        if !is_continuation(byte) {
            return 1;
        }
        cp = cp.wrapping_shl(6) | (u32::from(byte) & 0x3F);
    }
    if cp < floor || (0xD800..=0xDFFF).contains(&cp) {
        return 1;
    }
    want
}

pub fn chars_prefix(input: &[u8], n: usize, utf8: bool) -> Vec<u8> {
    if !utf8 {
        return input.iter().take(n).copied().collect();
    }
    let mut end = 0usize;
    for _ in 0..n {
        let step = libc_char_len(input.get(end..).unwrap_or(&[]));
        if step == 0 {
            break;
        }
        end = end.saturating_add(step);
    }
    input.get(..end).unwrap_or(input).to_vec()
}

pub fn bash_i64(text: &str) -> Option<i64> {
    let trimmed = text.trim_matches([' ', '\t', '\n']);
    let (negative, body) = match trimmed.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, trimmed.strip_prefix('+').unwrap_or(trimmed)),
    };
    let (radix, digits) =
        if let Some(hex) = body.strip_prefix("0x").or_else(|| body.strip_prefix("0X")) {
            (16u32, hex)
        } else if body.len() > 1 && body.starts_with('0') {
            (8u32, body)
        } else {
            (10u32, body)
        };
    if body.is_empty() && !trimmed.is_empty() {
        return None;
    }
    let mut value: i64 = 0;
    for c in digits.chars() {
        let digit = c.to_digit(radix)?;
        value = value
            .wrapping_mul(i64::from(radix))
            .wrapping_add(i64::from(digit));
    }
    Some(if negative {
        value.wrapping_neg()
    } else {
        value
    })
}

pub fn is_c_space(byte: u8) -> bool {
    matches!(byte, 0x09..=0x0D | 0x20)
}

pub fn is_jq_space(c: char) -> bool {
    c.is_whitespace()
}
