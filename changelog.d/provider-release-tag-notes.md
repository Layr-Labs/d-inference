### Release notes without tag signatures

- Publish provider release notes from the original tag annotation without its
  SSH or PGP signature, preserving multiline paragraphs and blank lines. A signed
  tag's signature block was included in the published notes (provider 0.9.20
  shows it as encoded bullet points); it stays available from git as verification
  data.
