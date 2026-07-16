use std::fs;
use std::process::Command;
use tempfile::TempDir;

#[test]
fn fixture_generation_fails_when_immutable_artifacts_are_missing() {
    let temp = TempDir::new().unwrap();
    let manifest = temp.path().join("manifest.json");
    let output = temp.path().join("generated.json");
    fs::write(
        &manifest,
        br#"{
          "model_id": "missing-model",
          "model_type": "fixture",
          "files": [
            {
              "path": "tokenizer.json",
              "role": "tokenizer",
              "size_bytes": 1,
              "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
            }
          ]
        }"#,
    )
    .unwrap();
    let source_cases = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../fixtures/prompt-contract/v1/corpus.json");
    let cases = temp.path().join("corpus.json");
    let corpus = fs::read_to_string(source_cases).unwrap();
    fs::write(&cases, corpus).unwrap();
    let result = Command::new(env!("CARGO_BIN_EXE_prompt-fixtures"))
        .args([
            "--manifest",
            manifest.to_str().unwrap(),
            "--artifact-root",
            temp.path().to_str().unwrap(),
            "--cases",
            cases.to_str().unwrap(),
            "--output",
            output.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(!result.status.success());
    assert!(
        String::from_utf8_lossy(&result.stderr)
            .contains("production prompt contract is not parity-ready")
    );
    assert!(!output.exists());
}
