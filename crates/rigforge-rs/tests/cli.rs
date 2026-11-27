use std::process::Command;

fn repo_version() -> String {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../VERSION");
    std::fs::read_to_string(path)
        .unwrap_or_else(|err| panic!("cannot read {path}: {err}"))
        .trim()
        .to_owned()
}

#[test]
fn version_flag_prints_the_repository_version() {
    let output = Command::new(env!("CARGO_BIN_EXE_rigforge-rs"))
        .arg("--version")
        .output()
        .expect("the built binary runs");
    assert!(output.status.success(), "exit {}", output.status);
    let stdout = String::from_utf8(output.stdout).expect("utf-8 output");
    assert_eq!(stdout.trim_end(), format!("rigforge-rs {}", repo_version()));
}
