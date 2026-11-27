use rigforge_core::num::{Num, double_text};
use rigforge_core::text::{bash_i64, chars_prefix, jq_utf8};

struct Rng(u64);

impl Rng {
    fn step(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }

    fn below(&mut self, n: usize) -> usize {
        usize::try_from(self.step() % (n as u64)).unwrap_or(0)
    }

    fn pick<'a, T>(&mut self, items: &'a [T]) -> Option<&'a T> {
        let at = self.below(items.len());
        items.get(at)
    }
}

const BYTES: [u8; 20] = [
    0x00, 0x0a, 0x31, 0x41, 0x7f, 0x80, 0x9f, 0xbf, 0xc0, 0xc1, 0xc2, 0xdf, 0xe0, 0xe2, 0xed, 0xef,
    0xf0, 0xf4, 0xf5, 0xff,
];

fn bytes(rng: &mut Rng) -> Vec<u8> {
    let len = rng.below(40);
    (0..len)
        .map(|_| {
            if rng.below(2) == 0 {
                rng.pick(&BYTES).copied().unwrap_or(0)
            } else {
                u8::try_from(rng.step() & 0xFF).unwrap_or(0)
            }
        })
        .collect()
}

fn lexeme(rng: &mut Rng) -> String {
    const PARTS: [&str; 19] = [
        "0",
        "1",
        "9",
        "5",
        "00",
        "-",
        "+",
        ".",
        "e",
        "E",
        "e-",
        "E+",
        "inf",
        "nan",
        "x",
        "1000",
        "999999999",
        "1147483646",
        "7",
    ];
    let len = rng.below(8);
    (0..len).filter_map(|_| rng.pick(&PARTS).copied()).collect()
}

#[test]
fn repair_is_total_idempotent_and_keeps_valid_text() {
    let mut rng = Rng(0x9E37_79B9_7F4A_7C15);
    for _ in 0..20_000 {
        let input = bytes(&mut rng);
        let fixed = jq_utf8(&input);
        assert!(fixed.chars().count() <= input.len());
        assert_eq!(jq_utf8(fixed.as_bytes()), fixed);
        if let Ok(valid) = std::str::from_utf8(&input) {
            assert_eq!(valid, fixed);
        }
        let n = rng.below(12);
        let prefix = chars_prefix(&input, n, false);
        assert_eq!(prefix.len(), n.min(input.len()));
        let utf8 = chars_prefix(&input, n, true);
        assert!(input.starts_with(&utf8));
        assert!(utf8.len() >= prefix.len().min(input.len()).min(n));
    }
}

#[test]
fn numbers_never_panic_and_stay_stable() {
    let mut rng = Rng(0xD1B5_4A32_D192_ED03);
    for _ in 0..20_000 {
        let text = lexeme(&mut rng);
        let _ = Num::tonumber(&text);
        let _ = bash_i64(&text);
        if let Ok(num) = Num::literal(&text) {
            let printed = num.lit();
            if num.f64().is_finite() && !printed.contains('e') {
                let again = Num::literal(printed).map(|n| n.lit().to_string());
                assert_eq!(again, Ok(printed.to_string()), "{text:?}");
            }
        }
    }
}

#[test]
fn double_text_round_trips_every_finite_value() {
    let mut rng = Rng(0x2545_F491_4F6C_DD1D);
    for _ in 0..20_000 {
        let f = f64::from_bits(rng.step());
        let text = double_text(f);
        if f.is_nan() {
            assert_eq!(text, "null");
        } else if f.is_infinite() {
            assert!(text.ends_with("e+308"));
        } else {
            assert_eq!(text.parse::<f64>(), Ok(f), "{text}");
        }
    }
}
