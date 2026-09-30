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

#[test]
fn normalization_v7_refuses_v6_and_mixed_metadata_even_with_a_warm_tokenizer() {
    use crate::contract::{ContractVersions, PromptArtifact};
    // Independently pinned by Node SHA-256 with exact UTF-8 byte ordering.
    // The same complete tiny payload contract is used by Go's causal test.
    const OLD_ID: &str = "35f35167c8444a2155269a8873c23e69980b334590762b31fb9bfe97250fa109";
    const NEW_ID: &str = "1916ae8b83dd77d3c6da1e0860672d79a9c146e2e661ae8e12b3182fb0b57132";
    let files: [(&str, &str, &[u8], &str); 4] = [
        (
            "config.json",
            "config",
            br#"{"model_type":"fixture"}"#,
            "d2445a28eada2ae5e33f04c7346241a88b84042ff69c25f248c7d9bd776f841c",
        ),
        (
            "tokenizer.json",
            "tokenizer",
            VALID_TOKENIZER,
            "591b0d73b5e85a973a76646a8a80117651178da79c01d0422dbaa1c62fa19a9d",
        ),
        (
            "tokenizer_config.json",
            "tokenizer",
            br#"{"chat_template":"{{ messages[0].content }}"}"#,
            "c54aee6c53a0c37cfb1336db462716220c80146dfa67bc4cdce63fbf99e687e0",
        ),
        (
            "chat_template.jinja",
            "template",
            b"{{ messages[0].content }}",
            "21b1d9c74a217211f93d54eca585c322017b9008d86619712ec946b10cf156f1",
        ),
    ];
    let artifacts = files
        .iter()
        .map(|(name, role, bytes, digest)| {
            assert_eq!(hex::encode(Sha256::digest(bytes)), *digest);
            PromptArtifact {
                path: (*name).into(),
                role: (*role).into(),
                size_bytes: bytes.len() as u64,
                sha256: (*digest).into(),
            }
        })
        .collect::<Vec<_>>();
    assert_eq!(
        compute_contract_id(&artifacts, &ContractVersions::default()).unwrap(),
        NEW_ID
    );
    let old_version = ContractVersions {
        normalization: "darkbloom-request-normalization-v6".into(),
        ..ContractVersions::default()
    };
    assert!(matches!(
        compute_contract_id(&artifacts, &old_version),
        Err(crate::contract::ContractError::UnsupportedVersions)
    ));

    for (name, id, versions) in [
        ("coherent-v6", OLD_ID, old_version.clone()),
        ("v7-directory-v6-semantics", NEW_ID, old_version),
        (
            "v6-directory-relabeled-v7",
            OLD_ID,
            ContractVersions::default(),
        ),
    ] {
        let temp = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(temp.path()).unwrap();
        let mut directory = root.join(NEW_ID);
        std::fs::create_dir(&directory).unwrap();
        for (file, _, bytes, _) in &files {
            std::fs::write(directory.join(file), bytes).unwrap();
        }
        let mut metadata = ContractMetadata {
            schema_version: 1,
            prompt_contract_id: NEW_ID.into(),
            model_id: "fixture".into(),
            model_type: Some("fixture".into()),
            model_aggregate_sha256: "0".repeat(64),
            artifacts: artifacts.clone(),
            versions: ContractVersions::default(),
        };
        std::fs::write(
            directory.join(METADATA_FILE),
            serde_json::to_vec(&metadata).unwrap(),
        )
        .unwrap();
        let tokenizers = SingleflightLru::new_weak(1);
        let current = load(&root, NEW_ID, &tokenizers).unwrap();
        assert_eq!(
            current.tokenizer.encode("hello", false).unwrap().get_ids(),
            &[1]
        );
        assert_eq!(
            current.metadata.versions.normalization,
            "darkbloom-request-normalization-v7"
        );

        // Mutate only semantic-version / identity dimensions in a test-owned
        // directory. Every payload remains present, hash-correct and unchanged.
        if id != NEW_ID {
            let next = root.join(id);
            std::fs::rename(&directory, &next).unwrap();
            directory = next;
        }
        metadata.prompt_contract_id = id.into();
        metadata.versions = versions;
        let before = serde_json::to_vec(&metadata).unwrap();
        std::fs::write(directory.join(METADATA_FILE), &before).unwrap();
        let root_handle = open_directory_tree(&root).unwrap();
        let directory_handle = open_directory_at(&root_handle, id).unwrap();
        for artifact in &artifacts {
            assert!(
                read_verified_file_at(
                    &directory_handle,
                    &artifact.path,
                    artifact.size_bytes,
                    &artifact.sha256
                )
                .is_ok(),
                "{name}/{}",
                artifact.path
            );
        }
        // With old-version fencing removed the coherent-v6 case is otherwise
        // fully loadable, so this assertion fails instead of finding missing IO.
        assert!(
            matches!(
                load(&root, id, &tokenizers),
                Err(ArtifactError::InvalidMetadata)
            ),
            "{name}"
        );
        assert_eq!(
            std::fs::read(directory.join(METADATA_FILE)).unwrap(),
            before
        );
        for (file, _, expected, _) in &files {
            assert_eq!(
                std::fs::read(directory.join(file)).unwrap().as_slice(),
                *expected,
                "{name}/{file}"
            );
        }
        // Keep the actual tokenizer warm through the refused load. A cached
        // tokenizer cannot bypass the semantic-version or artifact checks.
        assert_eq!(
            current.tokenizer.encode("hello", false).unwrap().get_ids(),
            &[1]
        );
    }
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
