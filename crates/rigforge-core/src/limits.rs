pub const MIB: usize = 1024 * 1024;
pub const CONFIG_BYTES: usize = MIB;
pub const REPLY_BYTES: usize = 4 * MIB;
pub const FILE_BYTES: usize = MIB;
pub const DEPTH_CONFIG: usize = 256;
pub const DEPTH_FEED: usize = 64;
pub const NODES_CONFIG: usize = 1_000_000;
pub const NODES_FEED: usize = 100_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct JsonLimits {
    pub bytes: usize,
    pub depth: usize,
    pub nodes: usize,
}

pub const CONFIG: JsonLimits = JsonLimits {
    bytes: CONFIG_BYTES,
    depth: DEPTH_CONFIG,
    nodes: NODES_CONFIG,
};

pub const REPLY: JsonLimits = JsonLimits {
    bytes: REPLY_BYTES,
    depth: DEPTH_FEED,
    nodes: NODES_FEED,
};

pub const FILE: JsonLimits = JsonLimits {
    bytes: FILE_BYTES,
    depth: DEPTH_FEED,
    nodes: NODES_FEED,
};
