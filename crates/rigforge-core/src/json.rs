use std::collections::HashMap;
use std::fmt;

use crate::error::{Error, Result};
use crate::limits::JsonLimits;
use crate::num::Num;
use crate::text::jq_utf8;

const BOM: [u8; 3] = [0xEF, 0xBB, 0xBF];
const LINEAR_KEYS: usize = 16;

#[derive(Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Num(Num),
    Str(String),
    Arr(Vec<Value>),
    Obj(Vec<(String, Value)>),
}

impl fmt::Debug for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Value(<json>)")
    }
}

impl Value {
    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Value::Obj(members) => members.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn members(&self) -> &[(String, Value)] {
        match self {
            Value::Obj(members) => members,
            _ => &[],
        }
    }
}

pub fn insert_member(
    members: &mut Vec<(String, Value)>,
    index: &mut HashMap<String, usize>,
    key: String,
    value: Value,
) {
    let found = if members.len() < LINEAR_KEYS {
        members.iter().position(|(k, _)| *k == key)
    } else {
        if index.is_empty() {
            for (at, (k, _)) in members.iter().enumerate() {
                index.insert(k.clone(), at);
            }
        }
        index.get(&key).copied()
    };
    match found {
        Some(at) => {
            if let Some(slot) = members.get_mut(at) {
                slot.1 = value;
            }
        }
        None => {
            if !index.is_empty() {
                index.insert(key.clone(), members.len());
            }
            members.push((key, value));
        }
    }
}

struct Parser<'a> {
    src: &'a [u8],
    pos: usize,
    limits: &'a JsonLimits,
    nodes: usize,
}

fn is_space(byte: u8) -> bool {
    matches!(byte, b' ' | b'\t' | b'\r' | b'\n')
}

fn is_delimiter(byte: u8) -> bool {
    is_space(byte) || matches!(byte, b'[' | b']' | b'{' | b'}' | b':' | b',' | b'"')
}

fn hex4(digits: &[u8]) -> Option<u32> {
    if digits.len() != 4 {
        return None;
    }
    let mut value = 0u32;
    for &byte in digits {
        let digit = char::from(byte).to_digit(16)?;
        value = value.checked_mul(16)?.checked_add(digit)?;
    }
    Some(value)
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<u8> {
        self.src.get(self.pos).copied()
    }

    fn skip_space(&mut self) {
        while self.peek().is_some_and(is_space) {
            self.pos = self.pos.saturating_add(1);
        }
    }

    fn advance(&mut self) {
        self.pos = self.pos.saturating_add(1);
    }

    fn token(&mut self) -> &'a [u8] {
        let src = self.src;
        let start = self.pos;
        while self.peek().is_some_and(|b| !is_delimiter(b)) {
            self.advance();
        }
        src.get(start..self.pos).unwrap_or(&[])
    }

    fn value(&mut self, depth: usize) -> Result<Value> {
        self.skip_space();
        self.nodes = self.nodes.saturating_add(1);
        if self.nodes > self.limits.nodes {
            return Err(Error::Nodes);
        }
        match self.peek() {
            None => Err(Error::Syntax),
            Some(b'[') => self.array(depth),
            Some(b'{') => self.object(depth),
            Some(b'"') => {
                self.advance();
                self.string().map(Value::Str)
            }
            Some(_) => self.scalar(),
        }
    }

    fn scalar(&mut self) -> Result<Value> {
        let token = self.token();
        let literal = |word: &[u8], value: Value| {
            if token == word {
                Ok(value)
            } else {
                Err(Error::Syntax)
            }
        };
        match token.first() {
            None | Some(b'\'') => Err(Error::Syntax),
            Some(b't') => literal(b"true", Value::Bool(true)),
            Some(b'f') => literal(b"false", Value::Bool(false)),
            Some(b'n') if token.get(1) == Some(&b'u') => literal(b"null", Value::Null),
            Some(_) => {
                let text = std::str::from_utf8(token).map_err(|_| Error::Number)?;
                Num::literal(text).map(Value::Num)
            }
        }
    }

    fn enter(&self, used: usize, cost: usize) -> Result<usize> {
        if used >= self.limits.depth {
            return Err(Error::Depth);
        }
        Ok(used.saturating_add(cost))
    }

    fn array(&mut self, depth: usize) -> Result<Value> {
        let inner = self.enter(depth, 1)?;
        self.advance();
        let mut items = Vec::new();
        self.skip_space();
        if self.peek() == Some(b']') {
            self.advance();
            return Ok(Value::Arr(items));
        }
        loop {
            items.push(self.value(inner)?);
            self.skip_space();
            match self.peek() {
                Some(b',') => self.advance(),
                Some(b']') => {
                    self.advance();
                    return Ok(Value::Arr(items));
                }
                _ => return Err(Error::Syntax),
            }
        }
    }

    fn object(&mut self, depth: usize) -> Result<Value> {
        let inner = self.enter(depth, 2)?;
        self.advance();
        let mut members = Vec::new();
        let mut index = HashMap::new();
        self.skip_space();
        if self.peek() == Some(b'}') {
            self.advance();
            return Ok(Value::Obj(members));
        }
        loop {
            self.skip_space();
            if self.peek() != Some(b'"') {
                return Err(Error::Syntax);
            }
            self.advance();
            let key = self.string()?;
            self.skip_space();
            if self.peek() != Some(b':') {
                return Err(Error::Syntax);
            }
            self.advance();
            let value = self.value(inner)?;
            insert_member(&mut members, &mut index, key, value);
            self.skip_space();
            match self.peek() {
                Some(b',') => self.advance(),
                Some(b'}') => {
                    self.advance();
                    return Ok(Value::Obj(members));
                }
                _ => return Err(Error::Syntax),
            }
        }
    }

    fn escape(&mut self, out: &mut Vec<u8>) -> Result<()> {
        let code = self.peek().ok_or(Error::Syntax)?;
        self.advance();
        let plain = match code {
            b'"' => b'"',
            b'\\' => b'\\',
            b'/' => b'/',
            b'b' => 0x08,
            b'f' => 0x0C,
            b'n' => b'\n',
            b'r' => b'\r',
            b't' => b'\t',
            b'u' => return self.unicode(out),
            _ => return Err(Error::Syntax),
        };
        out.push(plain);
        Ok(())
    }

    fn four_digits(&mut self) -> Result<u32> {
        let end = self.pos.saturating_add(4);
        let digits = self.src.get(self.pos..end).ok_or(Error::Syntax)?;
        let value = hex4(digits).ok_or(Error::Syntax)?;
        self.pos = end;
        Ok(value)
    }

    fn unicode(&mut self, out: &mut Vec<u8>) -> Result<()> {
        let first = self.four_digits()?;
        let code = if (0xD800..=0xDBFF).contains(&first) {
            if self.src.get(self.pos..self.pos.saturating_add(2)) != Some(b"\\u") {
                return Err(Error::Syntax);
            }
            self.pos = self.pos.saturating_add(2);
            let second = self.four_digits()?;
            if !(0xDC00..=0xDFFF).contains(&second) {
                return Err(Error::Syntax);
            }
            0x1_0000 + (((first - 0xD800) << 10) | (second - 0xDC00))
        } else {
            first
        };
        let c = char::from_u32(code).unwrap_or('\u{FFFD}');
        out.extend_from_slice(c.encode_utf8(&mut [0u8; 4]).as_bytes());
        Ok(())
    }

    fn string(&mut self) -> Result<String> {
        let mut raw = Vec::new();
        loop {
            let byte = self.peek().ok_or(Error::Syntax)?;
            self.advance();
            match byte {
                b'"' => return Ok(jq_utf8(&raw)),
                b'\\' => self.escape(&mut raw)?,
                0x00..=0x1F => return Err(Error::Syntax),
                _ => raw.push(byte),
            }
        }
    }
}

fn strip_bom(src: &[u8]) -> Result<Option<&[u8]>> {
    for (at, want) in BOM.iter().enumerate() {
        match src.get(at) {
            Some(byte) if byte == want => {}
            Some(_) if at == 0 => return Ok(Some(src)),
            Some(_) => return Err(Error::Syntax),
            None => return Ok(None),
        }
    }
    Ok(src.get(BOM.len()..))
}

pub fn parse_all(src: &[u8], limits: &JsonLimits) -> Result<Vec<Value>> {
    if src.len() > limits.bytes {
        return Err(Error::Size);
    }
    let Some(body) = strip_bom(src)? else {
        return Ok(Vec::new());
    };
    let mut parser = Parser {
        src: body,
        pos: 0,
        limits,
        nodes: 0,
    };
    let mut docs = Vec::new();
    loop {
        parser.skip_space();
        if parser.peek().is_none() {
            return Ok(docs);
        }
        docs.push(parser.value(0)?);
    }
}

pub fn parse_one(src: &[u8], limits: &JsonLimits) -> Result<Value> {
    let mut docs = parse_all(src, limits)?.into_iter();
    let first = docs.next().ok_or(Error::Empty)?;
    if docs.next().is_some() {
        return Err(Error::Multiple);
    }
    Ok(first)
}
