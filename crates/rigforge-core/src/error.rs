use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    Number,
    Syntax,
    Depth,
    Nodes,
    Size,
    Empty,
    Multiple,
    Type,
}

pub type Result<T> = std::result::Result<T, Error>;

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Error::Number => "invalid numeric literal",
            Error::Syntax => "invalid JSON text",
            Error::Depth => "exceeds the depth limit for parsing",
            Error::Nodes => "exceeds the node limit for parsing",
            Error::Size => "exceeds the size limit for parsing",
            Error::Empty => "expected a JSON value",
            Error::Multiple => "unexpected extra JSON values",
            Error::Type => "operator applied to a value of the wrong type",
        })
    }
}

impl std::error::Error for Error {}
