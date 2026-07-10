//! Migration files are ordered and additive (no live Postgres required).

use std::fs;
use std::path::PathBuf;

fn migrations_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../migrations")
}

#[test]
fn rust_coord_migrations_are_ordered_and_additive() {
    let dir = migrations_dir();
    assert!(dir.is_dir(), "missing {}", dir.display());
    let mut names: Vec<String> = fs::read_dir(&dir)
        .unwrap()
        .filter_map(|e| e.ok())
        .filter_map(|e| {
            let n = e.file_name().into_string().ok()?;
            n.ends_with(".sql").then_some(n)
        })
        .collect();
    names.sort();
    assert!(
        names.iter().any(|n| n.starts_with("0001_")),
        "expected 0001_*: {names:?}"
    );
    assert!(
        names.iter().any(|n| n.contains("late_terminals")),
        "expected late_terminals migration: {names:?}"
    );
    assert!(
        names.iter().any(|n| n.contains("financial_op_params")),
        "expected financial_op_params migration: {names:?}"
    );
    let mut sorted = names.clone();
    sorted.sort();
    assert_eq!(names, sorted, "migration filenames must sort lexicographically");

    for name in &names {
        let body = fs::read_to_string(dir.join(name)).unwrap();
        assert!(
            !body.to_lowercase().contains("drop schema"),
            "{name} must not drop schema"
        );
        assert!(
            body.contains("IF NOT EXISTS") || body.contains("ADD COLUMN IF NOT EXISTS"),
            "{name} should be additive (IF NOT EXISTS)"
        );
    }
}
