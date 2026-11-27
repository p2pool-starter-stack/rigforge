use std::path::PathBuf;

fn section(text: &str, name: &str) -> Vec<String> {
    let header = format!("[{name}]");
    let mut inside = false;
    let mut lines = Vec::new();
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') {
            inside = trimmed == header;
            continue;
        }
        if inside && !trimmed.is_empty() {
            lines.push(trimmed.to_string());
        }
    }
    lines
}

fn manifest() -> Result<String, String> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Cargo.toml");
    std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))
}

#[test]
fn both_profiles_unwind() -> Result<(), String> {
    let text = manifest()?;
    for profile in ["profile.dev", "profile.release"] {
        let lines = section(&text, profile);
        if !lines.iter().any(|l| l == "panic = \"unwind\"") {
            return Err(format!("[{profile}] lacks panic = \"unwind\""));
        }
    }
    Ok(())
}

#[test]
fn clippy_deny_list_is_complete() -> Result<(), String> {
    let text = manifest()?;
    let lines = section(&text, "workspace.lints.clippy");
    for lint in [
        "unwrap_used",
        "expect_used",
        "panic",
        "indexing_slicing",
        "todo",
        "unreachable",
        "print_stdout",
        "print_stderr",
    ] {
        let want = format!("{lint} = \"deny\"");
        if !lines.contains(&want) {
            return Err(format!("workspace clippy lints lack {want}"));
        }
    }
    Ok(())
}
