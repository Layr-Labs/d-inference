use super::*;
use std::os::unix::fs::symlink;

#[test]
fn rejects_symlinked_artifact() {
    let temp = tempfile::tempdir().unwrap();
    let target = temp.path().join("target");
    let link = temp.path().join("link");
    std::fs::write(&target, b"secret").unwrap();
    symlink(&target, &link).unwrap();
    let root = open_directory_tree(&std::fs::canonicalize(temp.path()).unwrap()).unwrap();
    assert!(read_bounded_at(&root, "link", 1024).is_err());
}

#[test]
fn rejects_symlinked_ancestor() {
    let temp = tempfile::tempdir().unwrap();
    let target = temp.path().join("target");
    let link = temp.path().join("link");
    std::fs::create_dir(&target).unwrap();
    std::fs::write(target.join("artifact"), b"secret").unwrap();
    symlink(&target, &link).unwrap();
    let root = open_directory_tree(&std::fs::canonicalize(temp.path()).unwrap()).unwrap();
    assert!(read_bounded_at(&root, "link/artifact", 1024).is_err());
}

#[test]
fn matches_swift_chat_template_precedence() {
    let config = Map::from_iter([(
        "chat_template".into(),
        Value::String("config-template".into()),
    )]);

    assert_eq!(
        load_chat_template(
            Some(b"jinja-template"),
            Some(br#"{"chat_template":"json-template"}"#),
            &config
        )
        .unwrap(),
        Value::String("jinja-template".into())
    );
    assert_eq!(
        load_chat_template(None, Some(br#"{"chat_template":"json-template"}"#), &config).unwrap(),
        Value::String("json-template".into())
    );
    assert_eq!(
        load_chat_template(None, None, &config).unwrap(),
        Value::String("config-template".into())
    );
}

#[test]
fn verified_identical_tokenizers_share_ownership_but_contract_settings_do_not() {
    let temp = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(temp.path()).unwrap();
    let first_id = write_sharing_contract(&root, "first", VALID_TOKENIZER);
    let second_id = write_sharing_contract(&root, "second", VALID_TOKENIZER);
    let tokenizers = SingleflightLru::new_weak(2);
    let first = load(&root, &first_id, &tokenizers).unwrap();
    let second = load(&root, &second_id, &tokenizers).unwrap();
    assert!(Arc::ptr_eq(&first.tokenizer, &second.tokenizer));
    assert_ne!(first.chat_template, second.chat_template);
    assert_ne!(first.model_config, second.model_config);
    assert_ne!(first.tokenizer_config, second.tokenizer_config);
    assert_eq!(
        first.tokenizer.encode("hello", false).unwrap().get_ids(),
        &[1]
    );
    let changed = std::str::from_utf8(VALID_TOKENIZER)
        .unwrap()
        .replace("\"hello\":1", "\"hello\":2");
    let third_id = write_sharing_contract(&root, "third", changed.as_bytes());
    let third = load(&root, &third_id, &tokenizers).unwrap();
    assert!(!Arc::ptr_eq(&first.tokenizer, &third.tokenizer));
    assert_eq!(
        third.tokenizer.encode("hello", false).unwrap().get_ids(),
        &[2]
    );
    let weak = Arc::downgrade(&first.tokenizer);
    drop(first);
    assert!(weak.upgrade().is_some());
    drop(second);
    assert!(
        weak.upgrade().is_none(),
        "only live contracts should own tokenizer data"
    );
    let reloaded = load(&root, &first_id, &tokenizers).unwrap();
    assert_eq!(
        reloaded.tokenizer.encode("hello", false).unwrap().get_ids(),
        &[1]
    );
}

#[test]
fn shared_tokenizer_never_bypasses_each_contract_artifact_integrity() {
    let temp = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(temp.path()).unwrap();
    let first_id = write_sharing_contract(&root, "first", VALID_TOKENIZER);
    let second_id = write_sharing_contract(&root, "second", VALID_TOKENIZER);
    let tokenizers = SingleflightLru::new_weak(2);
    let first = load(&root, &first_id, &tokenizers).unwrap();
    let target = root.join(&second_id).join("tokenizer.json");
    let corrupt = std::str::from_utf8(VALID_TOKENIZER)
        .unwrap()
        .replace("hello", "jello");
    assert_eq!(corrupt.len(), VALID_TOKENIZER.len());
    std::fs::write(&target, corrupt).unwrap();
    assert!(load(&root, &second_id, &tokenizers).is_err());
    std::fs::write(&target, VALID_TOKENIZER).unwrap();
    let config = root.join(&second_id).join("config.json");
    let original = std::fs::read(&config).unwrap();
    std::fs::write(&config, b"corrupt").unwrap();
    assert!(load(&root, &second_id, &tokenizers).is_err());
    std::fs::write(&config, original).unwrap();
    let recovered = load(&root, &second_id, &tokenizers).unwrap();
    assert!(Arc::ptr_eq(&first.tokenizer, &recovered.tokenizer));
}

const VALID_TOKENIZER: &[u8] = br#"{"version":"1.0","truncation":null,"padding":null,"added_tokens":[],"normalizer":null,"pre_tokenizer":{"type":"Whitespace"},"post_processor":null,"decoder":null,"model":{"type":"WordLevel","vocab":{"[UNK]":0,"hello":1},"unk_token":"[UNK]"}}"#;

fn write_sharing_contract(root: &Path, variant: &str, tokenizer: &[u8]) -> String {
    use crate::contract::{ContractVersions, PromptArtifact};
    let contents = [
        ("tokenizer.json", "tokenizer", tokenizer.to_vec()),
        (
            "tokenizer_config.json",
            "tokenizer",
            serde_json::to_vec(
                &serde_json::json!({"chat_template":variant,"local_option":variant}),
            )
            .unwrap(),
        ),
        (
            "config.json",
            "config",
            serde_json::to_vec(&serde_json::json!({"model_type":"fixture","variant":variant}))
                .unwrap(),
        ),
    ];
    let artifacts = contents
        .iter()
        .map(|(path, role, bytes)| PromptArtifact {
            path: (*path).into(),
            role: (*role).into(),
            size_bytes: bytes.len() as u64,
            sha256: hex::encode(Sha256::digest(bytes)),
        })
        .collect::<Vec<_>>();
    let versions = ContractVersions::default();
    let id = compute_contract_id(&artifacts, &versions).unwrap();
    let directory = root.join(&id);
    std::fs::create_dir(&directory).unwrap();
    for (path, _, bytes) in contents {
        std::fs::write(directory.join(path), bytes).unwrap();
    }
    let metadata = ContractMetadata {
        schema_version: 1,
        prompt_contract_id: id.clone(),
        model_id: variant.into(),
        model_type: Some("fixture".into()),
        model_aggregate_sha256: hex::encode([0; 32]),
        artifacts,
        versions,
    };
    std::fs::write(
        directory.join(METADATA_FILE),
        serde_json::to_vec(&metadata).unwrap(),
    )
    .unwrap();
    id
}
