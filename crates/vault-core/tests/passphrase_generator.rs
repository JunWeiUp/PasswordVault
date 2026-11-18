use serde_json::{json, Value};
use std::collections::HashSet;
use vault_core::*;

fn call(s: &VaultSession, request: Value) -> Result<Value> {
    Ok(serde_json::from_str(&s.command(request.to_string())?).unwrap())
}

fn session(dir: &tempfile::TempDir) -> VaultSession {
    let s = VaultSession::new(dir.path().to_string_lossy().into()).unwrap();
    call(
        &s,
        json!({"op":"create","password":"synthetic generator password"}),
    )
    .unwrap();
    s
}

fn words() -> HashSet<&'static str> {
    passphrase_word_list().iter().copied().collect()
}

#[test]
fn passphrase_uses_requested_shape_and_only_list_words() {
    let list = words();
    assert_eq!(list.len(), 2048);
    for count in PASSPHRASE_MIN_WORDS..=PASSPHRASE_MAX_WORDS {
        for separator in PASSPHRASE_SEPARATORS {
            let phrase = generate_passphrase(count, separator, false, false).unwrap();
            let parts: Vec<&str> = phrase.split(separator).collect();
            assert_eq!(parts.len(), count, "{phrase}");
            assert!(parts.iter().all(|word| list.contains(word)), "{phrase}");
        }
    }
}

#[test]
fn passphrase_capitalize_and_number_options() {
    let list = words();
    for _ in 0..50 {
        let phrase = generate_passphrase(6, ".", true, true).unwrap();
        let parts: Vec<&str> = phrase.split('.').collect();
        assert_eq!(parts.len(), 6);
        let digits: Vec<char> = phrase.chars().filter(char::is_ascii_digit).collect();
        assert_eq!(digits.len(), 1, "exactly one digit in {phrase}");
        let with_digit = parts
            .iter()
            .filter(|p| p.ends_with(|c: char| c.is_ascii_digit()));
        assert_eq!(with_digit.count(), 1, "{phrase}");
        for part in parts {
            assert!(
                part.starts_with(|c: char| c.is_ascii_uppercase()),
                "{phrase}"
            );
            let base = part.trim_end_matches(|c: char| c.is_ascii_digit());
            assert!(
                list.contains(base.to_ascii_lowercase().as_str()),
                "{phrase}"
            );
        }
        let plain = generate_passphrase(4, "_", false, false).unwrap();
        assert!(!plain
            .chars()
            .any(|c| c.is_ascii_digit() || c.is_ascii_uppercase()));
    }
}

#[test]
fn passphrase_rejects_invalid_counts_and_separators() {
    for count in [0, 1, 2, 11, 64] {
        assert!(matches!(
            generate_passphrase(count, "-", false, false),
            Err(VaultError::InvalidData)
        ));
    }
    for separator in ["", ",", "/", "--", "\n", "\t", "é"] {
        assert!(matches!(
            generate_passphrase(5, separator, false, false),
            Err(VaultError::InvalidData)
        ));
    }
}

#[test]
fn passphrases_are_distinct() {
    let generated: HashSet<String> = (0..200)
        .map(|_| generate_passphrase(5, "-", false, false).unwrap())
        .collect();
    assert_eq!(generated.len(), 200);
    // Every position draws from the full list rather than a fixed word.
    let first: HashSet<String> = generated
        .iter()
        .map(|p| p.split('-').next().unwrap().to_owned())
        .collect();
    assert!(first.len() > 100, "first words: {}", first.len());
}

#[test]
fn generate_op_supports_passphrase_and_keeps_character_mode() {
    let dir = tempfile::tempdir().unwrap();
    let s = session(&dir);
    let list = words();

    let default = call(&s, json!({"op":"generate","mode":"passphrase"})).unwrap();
    let phrase = default["password"].as_str().unwrap();
    assert_eq!(phrase.split('-').count(), PASSPHRASE_DEFAULT_WORDS);
    assert!(phrase.split('-').all(|word| list.contains(word)));

    let custom = call(
        &s,
        json!({"op":"generate","mode":"passphrase","words":3,"separator":" ","capitalize":true,"number":true}),
    )
    .unwrap();
    let phrase = custom["password"].as_str().unwrap();
    assert_eq!(phrase.split(' ').count(), 3);
    assert_eq!(phrase.chars().filter(char::is_ascii_digit).count(), 1);

    for invalid in [
        json!({"op":"generate","mode":"passphrase","words":2}),
        json!({"op":"generate","mode":"passphrase","words":11}),
        json!({"op":"generate","mode":"passphrase","words":"5"}),
        json!({"op":"generate","mode":"passphrase","words":-1}),
        json!({"op":"generate","mode":"passphrase","separator":"+"}),
        json!({"op":"generate","mode":"passphrase","separator":1}),
        json!({"op":"generate","mode":"passphrase","capitalize":"yes"}),
        json!({"op":"generate","mode":"words"}),
        json!({"op":"generate","mode":1}),
    ] {
        assert!(
            matches!(call(&s, invalid.clone()), Err(VaultError::InvalidData)),
            "{invalid}"
        );
    }

    // Requests without a mode keep the original character generator and response key.
    let legacy = call(&s, json!({"op":"generate","length":24,"symbols":false})).unwrap();
    let password = legacy["password"].as_str().unwrap();
    assert_eq!(password.len(), 24);
    assert!(password.chars().all(|c| c.is_ascii_alphanumeric()));
    assert_eq!(
        call(&s, json!({"op":"generate"})).unwrap()["password"]
            .as_str()
            .unwrap()
            .len(),
        20
    );
    let explicit = call(
        &s,
        json!({"op":"generate","mode":"characters","length":8,"upper":false,"lower":false,"symbols":false}),
    )
    .unwrap();
    assert!(explicit["password"]
        .as_str()
        .unwrap()
        .chars()
        .all(|c| c.is_ascii_digit()));
    assert!(matches!(
        call(
            &s,
            json!({"op":"generate","upper":false,"lower":false,"digits":false,"symbols":false})
        ),
        Err(VaultError::InvalidData)
    ));
    assert!(matches!(
        call(&s, json!({"op":"generate","length":3})),
        Err(VaultError::InvalidData)
    ));
}
