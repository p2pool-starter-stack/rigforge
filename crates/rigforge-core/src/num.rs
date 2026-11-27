use crate::error::{Error, Result};

const EMAX: i128 = 999_999_999;
const ETINY: i128 = -1_147_483_646;
const EXP_CAP: i128 = 1_000_000_000_000_000_000;
const DOUBLE_MAX: &str = "1.7976931348623157e+308";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JqMode {
    Literal,
    Double,
}

pub fn jq_mode(version: &str) -> JqMode {
    let Some(rest) = version.trim().strip_prefix("jq-") else {
        return JqMode::Literal;
    };
    let mut parts = rest.splitn(3, '.');
    let major = parts.next().and_then(leading_number);
    let minor = parts.next().and_then(leading_number);
    match (major, minor) {
        (Some(0), _) => JqMode::Double,
        (Some(1), Some(minor)) if minor < 7 => JqMode::Double,
        _ => JqMode::Literal,
    }
}

fn leading_number(text: &str) -> Option<u64> {
    let end = text
        .find(|c: char| !c.is_ascii_digit())
        .unwrap_or(text.len());
    text.get(..end)?.parse().ok()
}

#[derive(Debug, Clone, PartialEq)]
pub struct Num {
    lit: String,
    f: f64,
    exact: f64,
}

struct Lexeme<'a> {
    negative: bool,
    int: &'a str,
    frac: &'a str,
    exp: i128,
}

fn parse_lexeme(text: &str) -> Option<Lexeme<'_>> {
    let (negative, body) = match text.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, text.strip_prefix('+').unwrap_or(text)),
    };
    let (mantissa, exp_text) = match body.find(['e', 'E']) {
        Some(at) => (body.get(..at)?, Some(body.get(at + 1..)?)),
        None => (body, None),
    };
    let (int, frac) = match mantissa.split_once('.') {
        Some((int, frac)) => (int, frac),
        None => (mantissa, ""),
    };
    let all_digits = |s: &str| s.bytes().all(|b| b.is_ascii_digit());
    if !all_digits(int) || !all_digits(frac) || (int.is_empty() && frac.is_empty()) {
        return None;
    }
    let exp = match exp_text {
        None => 0,
        Some(raw) => {
            let (exp_negative, digits) = match raw.strip_prefix('-') {
                Some(rest) => (true, rest),
                None => (false, raw.strip_prefix('+').unwrap_or(raw)),
            };
            if digits.is_empty() || !all_digits(digits) {
                return None;
            }
            let mut value: i128 = 0;
            for b in digits.bytes() {
                value = (value * 10 + i128::from(b - b'0')).min(EXP_CAP);
            }
            if exp_negative { -value } else { value }
        }
    };
    Some(Lexeme {
        negative,
        int,
        frac,
        exp,
    })
}

fn word_kind(text: &str) -> Option<bool> {
    let body = text
        .strip_prefix('-')
        .or_else(|| text.strip_prefix('+'))
        .unwrap_or(text);
    let lower = body.to_ascii_lowercase();
    if lower == "inf" || lower == "infinity" {
        return Some(false);
    }
    let payload = lower
        .strip_prefix("snan")
        .or_else(|| lower.strip_prefix("nan"))?;
    payload.bytes().all(|b| b.is_ascii_digit()).then_some(true)
}

pub fn is_nan_word(text: &str) -> bool {
    word_kind(text) == Some(true)
}

fn increment(digits: &str) -> String {
    let mut out: Vec<u8> = digits.bytes().collect();
    let mut carry = true;
    for slot in out.iter_mut().rev() {
        if !carry {
            break;
        }
        if *slot == b'9' {
            *slot = b'0';
        } else {
            *slot += 1;
            carry = false;
        }
    }
    let mut text = String::from_utf8_lossy(&out).into_owned();
    if carry {
        text.insert(0, '1');
    }
    text
}

fn scientific_string(negative: bool, coef: &str, exp: i128) -> String {
    let nd = i128::try_from(coef.len()).unwrap_or(i128::MAX);
    let adjusted = exp + nd - 1;
    let mut out = String::with_capacity(coef.len() + 24);
    if negative {
        out.push('-');
    }
    if exp <= 0 && adjusted >= -6 {
        if exp == 0 {
            out.push_str(coef);
        } else if nd > -exp {
            let split = usize::try_from(nd + exp).unwrap_or(0);
            let (head, tail) = coef.split_at_checked(split).unwrap_or((coef, ""));
            out.push_str(head);
            out.push('.');
            out.push_str(tail);
        } else {
            out.push_str("0.");
            out.push_str(&"0".repeat(usize::try_from(-exp - nd).unwrap_or(0)));
            out.push_str(coef);
        }
        return out;
    }
    let (first, rest) = coef.split_at_checked(1).unwrap_or((coef, ""));
    out.push_str(first);
    if !rest.is_empty() {
        out.push('.');
        out.push_str(rest);
    }
    out.push('E');
    out.push(if adjusted < 0 { '-' } else { '+' });
    out.push_str(&adjusted.abs().to_string());
    out
}

fn round_to_tiny(coef: &str, exp: i128) -> String {
    let nd = i128::try_from(coef.len()).unwrap_or(i128::MAX);
    let shift = ETINY - exp;
    if shift > nd {
        return "0".to_string();
    }
    let keep = usize::try_from(nd - shift).unwrap_or(0);
    let (head, dropped) = coef.split_at_checked(keep).unwrap_or((coef, ""));
    let round_up = dropped.bytes().next().is_some_and(|b| b >= b'5');
    match (head.is_empty(), round_up) {
        (true, false) => "0".to_string(),
        (true, true) => "1".to_string(),
        (false, true) => increment(head),
        (false, false) => head.to_string(),
    }
}

fn clean(lexeme: &Lexeme<'_>) -> Option<String> {
    let all = format!("{}{}", lexeme.int, lexeme.frac);
    let trimmed = all.trim_start_matches('0');
    let frac_len = i128::try_from(lexeme.frac.len()).unwrap_or(0);
    let mut exp = lexeme.exp - frac_len;
    if trimmed.is_empty() {
        exp = exp.clamp(ETINY, EMAX);
        return Some(scientific_string(lexeme.negative, "0", exp));
    }
    let nd = i128::try_from(trimmed.len()).unwrap_or(i128::MAX);
    if exp + nd - 1 > EMAX {
        return None;
    }
    if exp < ETINY {
        let coef = round_to_tiny(trimmed, exp);
        return Some(scientific_string(lexeme.negative, &coef, ETINY));
    }
    Some(scientific_string(lexeme.negative, trimmed, exp))
}

pub fn dec_clean(text: &str) -> Result<String> {
    let lexeme = parse_lexeme(text).ok_or(Error::Number)?;
    Ok(clean(&lexeme).unwrap_or_else(|| {
        if lexeme.negative {
            format!("-{DOUBLE_MAX}")
        } else {
            DOUBLE_MAX.to_string()
        }
    }))
}

pub fn double_text(f: f64) -> String {
    if f.is_nan() {
        return "null".to_string();
    }
    let sign = if f.is_sign_negative() { "-" } else { "" };
    if f.is_infinite() {
        return format!("{sign}{DOUBLE_MAX}");
    }
    if f == 0.0 {
        return format!("{sign}0");
    }
    let shortest = format!("{:e}", f.abs());
    let long = shortest.split('e').next().is_some_and(|m| m.len() == 18);
    let sci = if long {
        format!("{:.16e}", f.abs())
    } else {
        shortest
    };
    let (mantissa, exp_text) = sci.split_once('e').unwrap_or((sci.as_str(), "0"));
    let digits: String = mantissa.chars().filter(|c| *c != '.').collect();
    let exp10: i64 = exp_text.parse().unwrap_or(0);
    let n = i64::try_from(digits.len()).unwrap_or(0);
    let decpt = exp10 + 1;
    let at = |k: i64| usize::try_from(k).unwrap_or(0);
    let mut out = String::from(sign);
    if decpt <= -4 || decpt > n + 15 {
        let (first, rest) = digits.split_at_checked(1).unwrap_or((digits.as_str(), ""));
        out.push_str(first);
        if !rest.is_empty() {
            out.push('.');
            out.push_str(rest);
        }
        let e = decpt - 1;
        out.push('e');
        out.push(if e < 0 { '-' } else { '+' });
        out.push_str(&format!("{:02}", e.abs()));
    } else if decpt <= 0 {
        out.push_str("0.");
        out.push_str(&"0".repeat(at(-decpt)));
        out.push_str(&digits);
    } else if decpt >= n {
        out.push_str(&digits);
        out.push_str(&"0".repeat(at(decpt - n)));
    } else {
        let (head, tail) = digits
            .split_at_checked(at(decpt))
            .unwrap_or((digits.as_str(), ""));
        out.push_str(head);
        out.push('.');
        out.push_str(tail);
    }
    out
}

fn round_to_17(coef: &str, exp: i128) -> (String, i128) {
    let (head, dropped) = coef.split_at_checked(17).unwrap_or((coef, ""));
    if dropped.is_empty() {
        return (coef.to_string(), exp);
    }
    let shifted = exp + i128::try_from(dropped.len()).unwrap_or(0);
    let first = dropped.bytes().next().unwrap_or(b'0');
    let tail_zero = dropped.bytes().skip(1).all(|b| b == b'0');
    let head_odd = head.bytes().next_back().is_some_and(|b| b % 2 == 1);
    if first > b'5' || (first == b'5' && (!tail_zero || head_odd)) {
        (increment(head), shifted)
    } else {
        (head.to_string(), shifted)
    }
}

fn to_f64(lexeme: &Lexeme<'_>, step: bool) -> f64 {
    let all = format!("{}{}", lexeme.int, lexeme.frac);
    let trimmed = all.trim_start_matches('0');
    let sign = if lexeme.negative { -1.0 } else { 1.0 };
    if trimmed.is_empty() {
        return sign * 0.0;
    }
    let frac_len = i128::try_from(lexeme.frac.len()).unwrap_or(0);
    let exp = lexeme.exp - frac_len;
    let (coef, exp) = if step {
        round_to_17(trimmed, exp)
    } else {
        (trimmed.to_string(), exp)
    };
    let value: f64 = format!("{coef}e{exp}").parse().unwrap_or(f64::NAN);
    sign * value
}

impl Num {
    pub fn literal(text: &str) -> Result<Num> {
        if let Some(is_nan) = word_kind(text) {
            if is_nan {
                return Ok(Num::computed(f64::NAN));
            }
            let f = if text.starts_with('-') {
                f64::NEG_INFINITY
            } else {
                f64::INFINITY
            };
            return Ok(Num::computed(f));
        }
        let lexeme = parse_lexeme(text).ok_or(Error::Number)?;
        let f = to_f64(&lexeme, true);
        let exact = to_f64(&lexeme, false);
        let lit = clean(&lexeme).unwrap_or_else(|| double_text(f));
        Ok(Num { lit, f, exact })
    }

    pub fn computed(f: f64) -> Num {
        Num {
            lit: double_text(f),
            f,
            exact: f,
        }
    }

    pub fn tonumber(text: &str) -> Result<Num> {
        let cut = text.split('\0').next().unwrap_or("");
        let body = cut.strip_prefix('\u{FEFF}').unwrap_or(cut);
        let mut runs = body
            .split([' ', '\t', '\r', '\n'])
            .filter(|run| !run.is_empty());
        let first = runs.next().ok_or(Error::Number)?;
        if runs.next().is_some() {
            return Err(Error::Number);
        }
        Num::literal(first)
    }

    pub fn lit(&self) -> &str {
        &self.lit
    }

    pub fn f64(&self) -> f64 {
        self.f
    }

    pub fn exact(&self) -> f64 {
        self.exact
    }

    pub fn is_nan(&self) -> bool {
        self.f.is_nan()
    }

    pub fn text(&self, mode: JqMode) -> String {
        match mode {
            JqMode::Literal => self.lit.clone(),
            JqMode::Double => double_text(self.exact),
        }
    }

    pub fn reread(&self, mode: JqMode) -> Num {
        if self.f.is_nan() {
            return self.clone();
        }
        Num::literal(&self.text(mode)).unwrap_or_else(|_| self.clone())
    }

    pub fn is_plain_int(&self) -> bool {
        let digits = self.lit.strip_prefix('-').unwrap_or(&self.lit);
        !digits.is_empty()
            && digits.bytes().all(|b| b.is_ascii_digit())
            && self.lit == double_text(self.f)
    }
}
