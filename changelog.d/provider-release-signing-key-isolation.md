### Provider release signing key isolation

- The provider release keeps its signing key for two steps of job
  `build-and-release`: the certificate import and the `codesign` calls. The
  unsigned runtime smoke runs before the import. The evaluator check, the final
  runtime smoke, the version check and the cluster runtime facts run after the
  keychain is deleted.
- The provider release and `Provider Signing Validation` import the certificate
  with `scripts/import-signing-certificate.sh`: a random keychain password, a
  non-extractable key that only `codesign` may use, and a certificate file that
  exists only under `RUNNER_TEMP`. `scripts/remove-signing-keychain.sh` deletes
  the keychain and fails while the identity is still listed.
- The notarization credentials are in the environment of the `notarytool` step
  only.
- The signing jobs download the unsigned build by artifact id and digest.
- The publication jobs install the AWS CLI from
  `scripts/provider-release-publication-requirements.txt` with
  `pip install --require-hashes`, before their credentials are resolved.
- `publish-release` is the only job of the release lane with `contents: write`.
- `Provider Signing Validation` requires a dispatch on `master` and a
  `source_sha` on `master`'s ancestry.
