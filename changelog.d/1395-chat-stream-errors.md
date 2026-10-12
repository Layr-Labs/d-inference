### Chat stream errors

- Show provider failures and timeouts received during chat streaming as errors instead of marking an empty or partial response complete. Plaintext and sender-sealed streams stop at the first error event and use the existing retry UI.
