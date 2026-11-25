#![forbid(unsafe_code)]

use std::io::Write;
use std::process::ExitCode;

fn main() -> ExitCode {
    if !rigforge_core::is_version_request(std::env::args_os().skip(1)) {
        let _ = writeln!(std::io::stderr(), "usage: rigforge-rs --version");
        return ExitCode::from(2);
    }
    let line = rigforge_core::version_line("rigforge-rs", env!("CARGO_PKG_VERSION"));
    match writeln!(std::io::stdout().lock(), "{line}") {
        Ok(()) => ExitCode::SUCCESS,
        Err(_) => ExitCode::FAILURE,
    }
}
