### MiMo prompt fixture downloads follow only allowed redirects

`scripts/prepare-mimo-prompt-fixtures.py` now follows a redirect only when the
target keeps the scheme, host and port of the URL that redirected, or when
`https://huggingface.co` redirects over HTTPS to a Hugging Face CDN host
(`hf.co` or a name that ends in `.hf.co`), where the Hub serves
`tokenizer.json`. Any other redirect (another host, another port or plain HTTP)
fails at once, is not retried, and its target is never requested. Before, the
script followed any redirect and refused only a final plain-HTTP URL. The
prompt fixture downloaders now share this rule in `scripts/fixture_redirects.py`.
