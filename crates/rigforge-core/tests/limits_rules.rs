use rigforge_core::error::Error;
use rigforge_core::json::parse_all;
use rigforge_core::limits::{CONFIG, FILE, MIB, REPLY};

#[test]
fn every_limit_has_its_exact_value() {
    assert_eq!(MIB, 1_048_576);
    let table = [
        (CONFIG, (1_048_576, 256, 1_000_000)),
        (REPLY, (4_194_304, 64, 100_000)),
        (FILE, (1_048_576, 64, 100_000)),
    ];
    for (limits, (bytes, depth, nodes)) in table {
        assert_eq!(
            (limits.bytes, limits.depth, limits.nodes),
            (bytes, depth, nodes)
        );
    }
}

#[test]
fn byte_caps_have_exact_edges() {
    for limits in [CONFIG, REPLY, FILE] {
        let at = vec![b' '; limits.bytes];
        let over = vec![b' '; limits.bytes + 1];
        assert!(parse_all(&at, &limits).is_ok());
        assert_eq!(parse_all(&over, &limits), Err(Error::Size));
    }
}

#[test]
fn node_caps_count_across_the_whole_input() {
    for limits in [REPLY, FILE] {
        let at = "0 ".repeat(limits.nodes);
        let over = "0 ".repeat(limits.nodes + 1);
        assert!(parse_all(at.as_bytes(), &limits).is_ok());
        assert_eq!(parse_all(over.as_bytes(), &limits), Err(Error::Nodes));
    }
}
