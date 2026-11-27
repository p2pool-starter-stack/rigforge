use std::fmt::Write;

use crate::json::Value;
use crate::num::JqMode;

pub fn escape_into(out: &mut String, text: &str) {
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{08}' => out.push_str("\\b"),
            '\t' => out.push_str("\\t"),
            '\n' => out.push_str("\\n"),
            '\u{0C}' => out.push_str("\\f"),
            '\r' => out.push_str("\\r"),
            '\u{00}'..='\u{1F}' | '\u{7F}' => {
                let _ = write!(out, "\\u{:04x}", u32::from(c));
            }
            _ => out.push(c),
        }
    }
    out.push('"');
}

fn scalar_into(out: &mut String, value: &Value, mode: JqMode) -> bool {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(true) => out.push_str("true"),
        Value::Bool(false) => out.push_str("false"),
        Value::Num(n) => out.push_str(&n.text(mode)),
        Value::Str(s) => escape_into(out, s),
        Value::Arr(_) | Value::Obj(_) => return false,
    }
    true
}

fn compact_into(out: &mut String, value: &Value, mode: JqMode) {
    if scalar_into(out, value, mode) {
        return;
    }
    match value {
        Value::Arr(items) => {
            out.push('[');
            for (at, item) in items.iter().enumerate() {
                if at > 0 {
                    out.push(',');
                }
                compact_into(out, item, mode);
            }
            out.push(']');
        }
        Value::Obj(members) => {
            out.push('{');
            for (at, (key, item)) in members.iter().enumerate() {
                if at > 0 {
                    out.push(',');
                }
                escape_into(out, key);
                out.push(':');
                compact_into(out, item, mode);
            }
            out.push('}');
        }
        _ => {}
    }
}

fn indent(out: &mut String, level: usize) {
    out.push('\n');
    for _ in 0..level {
        out.push_str("  ");
    }
}

fn pretty_into(out: &mut String, value: &Value, mode: JqMode, level: usize) {
    if scalar_into(out, value, mode) {
        return;
    }
    let inner = level.saturating_add(1);
    match value {
        Value::Arr(items) if !items.is_empty() => {
            out.push('[');
            for (at, item) in items.iter().enumerate() {
                if at > 0 {
                    out.push(',');
                }
                indent(out, inner);
                pretty_into(out, item, mode, inner);
            }
            indent(out, level);
            out.push(']');
        }
        Value::Obj(members) if !members.is_empty() => {
            out.push('{');
            for (at, (key, item)) in members.iter().enumerate() {
                if at > 0 {
                    out.push(',');
                }
                indent(out, inner);
                escape_into(out, key);
                out.push_str(": ");
                pretty_into(out, item, mode, inner);
            }
            indent(out, level);
            out.push('}');
        }
        Value::Arr(_) => out.push_str("[]"),
        _ => out.push_str("{}"),
    }
}

pub fn compact(value: &Value, mode: JqMode) -> String {
    let mut out = String::new();
    compact_into(&mut out, value, mode);
    out
}

pub fn pretty(value: &Value, mode: JqMode) -> String {
    let mut out = String::new();
    pretty_into(&mut out, value, mode, 0);
    out
}

pub fn sorted(value: Value) -> Value {
    match value {
        Value::Arr(items) => Value::Arr(items.into_iter().map(sorted).collect()),
        Value::Obj(members) => {
            let mut members: Vec<(String, Value)> =
                members.into_iter().map(|(k, v)| (k, sorted(v))).collect();
            members.sort_by(|a, b| a.0.cmp(&b.0));
            Value::Obj(members)
        }
        other => other,
    }
}

pub fn reread(value: Value, mode: JqMode) -> Value {
    match value {
        Value::Num(n) if n.is_nan() => Value::Null,
        Value::Num(n) => Value::Num(n.reread(mode)),
        Value::Arr(items) => Value::Arr(items.into_iter().map(|v| reread(v, mode)).collect()),
        Value::Obj(members) => Value::Obj(
            members
                .into_iter()
                .map(|(k, v)| (k, reread(v, mode)))
                .collect(),
        ),
        other => other,
    }
}
