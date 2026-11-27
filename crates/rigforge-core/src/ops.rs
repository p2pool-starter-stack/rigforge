use std::collections::HashMap;

use crate::emit::pretty;
use crate::error::{Error, Result};
use crate::json::{Value, insert_member};
use crate::num::{JqMode, Num};

pub fn set_key(value: Value, key: &str, new: Value) -> Result<Value> {
    let mut members = match value {
        Value::Null => Vec::new(),
        Value::Obj(members) => members,
        _ => return Err(Error::Type),
    };
    insert_member(&mut members, &mut HashMap::new(), key.to_string(), new);
    Ok(Value::Obj(members))
}

pub fn plus(left: Value, right: Value) -> Result<Value> {
    match (left, right) {
        (Value::Null, other) | (other, Value::Null) => Ok(other),
        (Value::Obj(mut members), Value::Obj(extra)) => {
            let mut index = HashMap::new();
            for (key, value) in extra {
                insert_member(&mut members, &mut index, key, value);
            }
            Ok(Value::Obj(members))
        }
        _ => Err(Error::Type),
    }
}

pub fn alt(left: Value, right: Value) -> Value {
    match left {
        Value::Null | Value::Bool(false) => right,
        other => other,
    }
}

fn count(n: usize) -> Value {
    let capped = u32::try_from(n).unwrap_or(u32::MAX);
    Value::Num(Num::computed(f64::from(capped)))
}

pub fn jq_len(value: &Value, mode: JqMode) -> Result<Value> {
    match value {
        Value::Null => Ok(count(0)),
        Value::Bool(_) => Err(Error::Type),
        Value::Num(n) => {
            let double = match mode {
                JqMode::Literal => n.f64(),
                JqMode::Double => n.exact(),
            };
            Ok(Value::Num(Num::computed(double.abs())))
        }
        Value::Str(s) => Ok(count(s.chars().count())),
        Value::Arr(items) => Ok(count(items.len())),
        Value::Obj(members) => Ok(count(members.len())),
    }
}

pub fn pick3(value: &Value, keys: [&str; 3]) -> Result<Value> {
    if !matches!(value, Value::Null | Value::Obj(_)) {
        return Err(Error::Type);
    }
    let pick = |key: &str| {
        let found = value.get(key).cloned();
        (key.to_string(), found.unwrap_or(Value::Null))
    };
    Ok(Value::Obj(keys.into_iter().map(pick).collect()))
}

pub fn j_text(value: &Value, mode: JqMode) -> String {
    match value {
        Value::Str(s) => s.clone(),
        other => pretty(other, mode),
    }
}

pub fn raw_text(value: &Value, mode: JqMode) -> String {
    let mut text = j_text(value, mode);
    text.push('\n');
    text
}
