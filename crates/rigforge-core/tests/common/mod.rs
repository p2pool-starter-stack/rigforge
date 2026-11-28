#![allow(dead_code)]

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use rigforge_core::emit::compact;
use rigforge_core::error::Error;
use rigforge_core::json::{Value, parse_one};
use rigforge_core::limits::CONFIG;
use rigforge_core::num::JqMode;

pub type TestResult = Result<(), String>;

pub struct Row {
    pub input: Vec<u8>,
    pub status: i32,
    pub output: Vec<u8>,
    pub label: String,
}

pub struct Golden {
    pub args: Vec<String>,
    pub rows: Vec<Row>,
}

pub fn golden_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/golden/jq-1.7.1")
}

pub fn unhex(text: &str) -> Result<Vec<u8>, String> {
    if !text.len().is_multiple_of(2) {
        return Err(format!("odd hex length: {text}"));
    }
    text.as_bytes()
        .chunks(2)
        .map(|pair| {
            let digits = std::str::from_utf8(pair).map_err(|e| e.to_string())?;
            u8::from_str_radix(digits, 16).map_err(|e| e.to_string())
        })
        .collect()
}

pub fn load(name: &str) -> Result<Golden, String> {
    let path = golden_dir().join(format!("{name}.tsv"));
    let text = std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut lines = text.lines();
    let header = lines.next().ok_or("empty golden file")?;
    let args = header.split('\t').map(str::to_string).collect();
    let mut rows = Vec::new();
    for line in lines {
        let mut fields = line.splitn(4, '\t');
        let input = unhex(fields.next().ok_or("missing input")?)?;
        let status = fields
            .next()
            .ok_or("missing status")?
            .parse()
            .map_err(|_| "bad status".to_string())?;
        let output = unhex(fields.next().ok_or("missing output")?)?;
        let label = fields.next().unwrap_or("").to_string();
        rows.push(Row {
            input,
            status,
            output,
            label,
        });
    }
    Ok(Golden { args, rows })
}

pub fn run_jq(bin: &str, args: &[String], input: &[u8]) -> Result<(i32, Vec<u8>), String> {
    let mut child = Command::new(bin)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("{bin}: {e}"))?;
    let mut stdin = child.stdin.take().ok_or("no stdin")?;
    let data = input.to_vec();
    let writer = std::thread::spawn(move || {
        let _ = stdin.write_all(&data);
    });
    let result = child.wait_with_output().map_err(|e| e.to_string())?;
    let _ = writer.join();
    Ok((result.status.code().unwrap_or(-1), result.stdout))
}

#[cfg(unix)]
pub fn run_jq_argjson(bin: &str, text: &[u8]) -> Result<(i32, Vec<u8>), String> {
    use std::os::unix::ffi::OsStrExt;
    let result = Command::new(bin)
        .args(["-nc", "--argjson", "x"])
        .arg(std::ffi::OsStr::from_bytes(text))
        .arg("$x")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map_err(|e| format!("{bin}: {e}"))?;
    Ok((result.status.code().unwrap_or(-1), result.stdout))
}

pub fn ascii(input: &[u8]) -> Result<&str, String> {
    std::str::from_utf8(input).map_err(|e| e.to_string())
}

pub fn skip_line(message: &str) {
    let _ = writeln!(std::io::stderr(), "{message}");
}

pub fn compare<F>(name: &str, f: F) -> Result<(usize, usize), String>
where
    F: Fn(&[u8]) -> Result<Vec<u8>, Error>,
{
    let golden = load(name)?;
    let (mut accepted, mut rejected) = (0, 0);
    for row in &golden.rows {
        let shown = format!("{name} [{}]", row.label);
        match (f(&row.input), row.status) {
            (Ok(got), 0) if got == row.output => accepted += 1,
            (Ok(got), 0) => {
                return Err(format!(
                    "{shown}: got {:?}, jq {:?}",
                    String::from_utf8_lossy(&got),
                    String::from_utf8_lossy(&row.output)
                ));
            }
            (Err(_), status) if status != 0 => rejected += 1,
            (Ok(_), status) => return Err(format!("{shown}: accepted, jq status {status}")),
            (Err(e), _) => return Err(format!("{shown}: rejected ({e}), jq printed a value")),
        }
    }
    Ok((accepted, rejected))
}

pub fn doc(text: &str) -> Result<Value, String> {
    let parsed = parse_one(text.as_bytes(), &CONFIG);
    parsed.map_err(|e| format!("{text:?}: {e}"))
}

pub fn lit(text: &str) -> Result<String, String> {
    let value = doc(text)?;
    Ok(compact(&value, JqMode::Literal))
}

pub fn nested(open: &str, close: &str, levels: usize) -> String {
    format!("{}0{}", open.repeat(levels), close.repeat(levels))
}

pub struct Rng(pub u64);

impl Rng {
    pub fn step(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }

    pub fn below(&mut self, n: usize) -> usize {
        usize::try_from(self.step() % (n.max(1) as u64)).unwrap_or(0)
    }

    pub fn pick<'a, T>(&mut self, items: &'a [T]) -> Option<&'a T> {
        let at = self.below(items.len());
        items.get(at)
    }
}
