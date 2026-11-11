### Developer tooling

- Add an offline GPT-OSS publisher checkpoint repacker that preserves MXFP4
  experts and BF16 non-expert tensors, with source/output verification and
  comparison receipts. Add frozen-request replay guards for paged attention,
  effective prefix reuse and complete streams. These tools do not change the
  registered model or establish candidate qualification.
