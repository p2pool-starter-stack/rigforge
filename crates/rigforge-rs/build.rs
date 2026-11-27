#![allow(clippy::print_stdout, clippy::print_stderr)]

use std::env;
use std::fs;
use std::path::Path;
use std::process::ExitCode;

fn main() -> ExitCode {
    let version_path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../VERSION");
    println!("cargo:rerun-if-changed={}", version_path.display());
    match fs::read_to_string(&version_path) {
        Ok(text) => {
            let version = text.trim();
            if version.is_empty() {
                eprintln!("rigforge-rs build: {} is empty", version_path.display());
                return ExitCode::FAILURE;
            }
            println!("cargo:rustc-env=RIGFORGE_VERSION={version}");
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!(
                "rigforge-rs build: cannot read {}: {err}",
                version_path.display()
            );
            ExitCode::FAILURE
        }
    }
}
