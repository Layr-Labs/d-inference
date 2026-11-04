### `darkbloom cluster` counts only the disk space that is free now

- Before a model is downloaded or copied between the two Macs, each Mac that receives it must have the model's size free on disk now, plus 2.1 GB to spare. Space macOS could free later is no longer counted, such as Time Machine local snapshots or files iCloud keeps elsewhere. On one Mac Studio, macOS reported 256.6 GB available with only 54.1 GB actually free, and the setup offered a 172.9 GB download that could not fit.
- When that space would have made room, the refusal says so: "Can't start Xiaomi: MiMo-V2.6-Flash: this Mac has 54.1 GB free; the model needs 172.9 GB and 2.1 GB to spare. macOS could free up to 202.5 GB more (purgeable files such as local snapshots), but Darkbloom doesn't count on it. Free space, then run `darkbloom cluster` again."
- The model list shows such a model last, ending "not enough free disk". The setup's Disk line and its low-disk warning use the same figure.
