mod common;

use common::{TestResult, ascii, load};
use rigforge_core::text::{is_jq_space, jq_utf8};

#[test]
fn utf8_repair_matches_jq() -> TestResult {
    let golden = load("str-repair")?;
    if golden.rows.len() < 40 {
        return Err("too few repair rows".to_string());
    }
    for row in &golden.rows {
        let got = jq_utf8(&row.input);
        if got.as_bytes() != row.output.as_slice() {
            return Err(format!(
                "[{}] input {:02x?}: got {:02x?}, jq {:02x?}",
                row.label,
                row.input,
                got.as_bytes(),
                row.output
            ));
        }
    }
    Ok(())
}

#[test]
fn jq_space_set_matches_every_scalar_value() -> TestResult {
    let golden = load("space-s")?;
    let row = golden.rows.first().ok_or("no row")?;
    let text = ascii(&row.output)?.trim();
    let list = text
        .strip_prefix('[')
        .and_then(|t| t.strip_suffix(']'))
        .ok_or("not a list")?;
    let spaces: Vec<u32> = list
        .split(',')
        .map(|n| n.parse().map_err(|_| format!("bad number {n}")))
        .collect::<Result<_, _>>()?;
    if spaces.len() < 20 {
        return Err("space list too short".to_string());
    }
    for code in 0..=0x10FFFFu32 {
        let Some(c) = char::from_u32(code) else {
            continue;
        };
        if is_jq_space(c) != spaces.contains(&code) {
            return Err(format!("U+{code:04X}: is_jq_space disagrees with jq"));
        }
    }
    Ok(())
}

#[test]
fn escape_rows_are_well_formed() -> TestResult {
    let golden = load("str-escape")?;
    let compact_ok = golden.rows.iter().filter(|r| r.status == 0).count();
    let rejected = golden.rows.iter().filter(|r| r.status != 0).count();
    if golden.args != ["-c", "."] || compact_ok < 30 || rejected < 3 {
        return Err("str-escape golden file changed shape".to_string());
    }
    Ok(())
}
