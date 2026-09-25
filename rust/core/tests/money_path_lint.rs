use std::fs;
use std::path::Path;

#[test]
fn money_path_contains_no_floating_point_types() {
    let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut violations = Vec::new();

    for entry in fs::read_dir(source).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().and_then(|value| value.to_str()) != Some("rs") {
            continue;
        }
        let contents = fs::read_to_string(&path).unwrap();
        for forbidden in ["f32", "f64"] {
            if contents.contains(forbidden) {
                violations.push(format!("{} contains {forbidden}", path.display()));
            }
        }
    }

    assert!(violations.is_empty(), "{}", violations.join("\n"));
}
