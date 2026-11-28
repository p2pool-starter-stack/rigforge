#![forbid(unsafe_code)]

pub mod emit;
pub mod error;
pub mod json;
pub mod limits;
pub mod num;
pub mod ops;
pub mod sha256;
pub mod text;

use std::ffi::OsString;

pub fn version_line(name: &str, version: &str) -> String {
    format!("{name} {version}")
}

pub fn is_version_request<I>(args: I) -> bool
where
    I: IntoIterator<Item = OsString>,
{
    let mut args = args.into_iter();
    args.next().is_some_and(|arg| arg == "--version") && args.next().is_none()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<OsString> {
        list.iter().map(OsString::from).collect()
    }

    #[test]
    fn version_line_joins_name_and_version() {
        assert_eq!(version_line("rigforge-rs", "0.0.0"), "rigforge-rs 0.0.0");
    }

    #[test]
    fn only_a_lone_version_flag_is_a_version_request() {
        assert!(is_version_request(args(&["--version"])));
        assert!(!is_version_request(args(&[])));
        assert!(!is_version_request(args(&["--help"])));
        assert!(!is_version_request(args(&["--version", "extra"])));
    }
}
