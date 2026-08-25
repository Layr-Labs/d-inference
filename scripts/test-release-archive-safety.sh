#!/bin/bash
set -euo pipefail

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-archive-safety.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
CANONICAL="$REPO_ROOT/scripts/install.sh"
EMBEDDED="$REPO_ROOT/coordinator/api/install.sh"

"$REPO_ROOT/scripts/sync-install-embed.sh" check
bash -n "$CANONICAL"
bash -n "$EMBEDDED"

for script in "$CANONICAL" "$EMBEDDED"; do
    grep -Fqx \
        'RELEASE_ARCHIVE_MAX_COMPRESSED_BYTES=2147483648' "$script"
    grep -Fqx \
        'RELEASE_ARCHIVE_MAX_EXPANDED_BYTES=4294967296' "$script"
    grep -Fqx \
        'RELEASE_ARCHIVE_MAX_ENTRIES=16384' "$script"
    grep -Fqx \
        'RELEASE_ARCHIVE_MAX_PATH_BYTES=4096' "$script"
    grep -Fqx \
        'RELEASE_ARCHIVE_MAX_COMPONENT_BYTES=255' "$script"
    grep -Fqx \
        'RELEASE_ARCHIVE_MAX_METADATA_BYTES=1048576' "$script"
done

cat > "$ROOT/make-tar.pl" <<'PERL'
use strict;
use warnings;
use bytes;

binmode(STDOUT);
my $mode = shift(@ARGV) // die("fixture mode required\n");
my $block_size = 512;

sub write_field {
    my ($header, $offset, $length, $value) = @_;
    die("field too long\n") if length($value) > $length;
    substr($$header, $offset, length($value), $value);
}

sub tar_header {
    my ($name, $typeflag, $body_size, $raw_size, $raw_mode) = @_;
    my $header = "\0" x $block_size;
    write_field(\$header, 0, 100, $name);
    write_field(
        \$header,
        100,
        8,
        defined($raw_mode) ? $raw_mode : "0000755\0",
    );
    write_field(\$header, 108, 8, "0000000\0");
    write_field(\$header, 116, 8, "0000000\0");
    my $size_field = defined($raw_size)
        ? $raw_size
        : sprintf("%011o\0", $body_size);
    write_field(\$header, 124, 12, $size_field);
    write_field(\$header, 136, 12, "00000000000\0");
    substr($header, 148, 8, " " x 8);
    substr($header, 156, 1, $typeflag);
    write_field(\$header, 257, 6, "ustar\0");
    write_field(\$header, 263, 2, "00");
    my $sum = 0;
    $sum += $_ for unpack("C*", $header);
    substr($header, 148, 8, sprintf("%06o\0 ", $sum));
    return $header;
}

sub emit_entry {
    my ($name, $typeflag, $body, $raw_size, $omit_body, $raw_mode) = @_;
    $body //= "";
    print tar_header(
        $name,
        $typeflag,
        length($body),
        $raw_size,
        $raw_mode,
    );
    return if $omit_body;
    print $body;
    my $padding = ($block_size - length($body) % $block_size) % $block_size;
    print "\0" x $padding;
}

sub pax_record {
    my ($key, $value) = @_;
    my $body = "$key=$value\n";
    my $length = length($body) + 2;
    while (1) {
        my $record = "$length $body";
        return $record if length($record) == $length;
        $length = length($record);
    }
}

if ($mode eq "large") {
    emit_entry(
        "large-sparse-payload",
        "0",
        "",
        sprintf("%011o\0", 4294967297),
        1,
    );
} elsif ($mode eq "negative") {
    emit_entry("negative", "0", "", pack("C*", (0xff) x 12), 1);
} elsif ($mode eq "overflow") {
    emit_entry(
        "overflow",
        "0",
        "",
        pack("C*", 0x80, (0xff) x 11),
        1,
    );
} elsif ($mode eq "duplicate") {
    emit_entry("./bin/darkbloom", "0", "", undef, 0);
    emit_entry("bin/darkbloom", "0", "", undef, 0);
} elsif ($mode eq "conflict") {
    emit_entry("Darkbloom.app", "0", "", undef, 0);
    emit_entry(
        "Darkbloom.app/Contents/file",
        "0",
        "",
        undef,
        0,
    );
} elsif ($mode eq "absolute") {
    emit_entry("/tmp/escape", "0", "", undef, 0);
} elsif ($mode eq "traversal") {
    emit_entry("bin/../escape", "0", "", undef, 0);
} elsif ($mode eq "symlink") {
    emit_entry("dangerous", "2", "", undef, 0);
} elsif ($mode eq "fifo") {
    emit_entry("dangerous", "6", "", undef, 0);
} elsif ($mode eq "sparse") {
    emit_entry("dangerous", "S", "", undef, 0);
} elsif ($mode eq "pax_sparse") {
    my $pax = pax_record("GNU.sparse.realsize", "4294967297");
    emit_entry("PaxHeaders/file", "x", $pax, undef, 0);
    emit_entry("file", "0", "", undef, 0);
} elsif ($mode eq "pax_sun_sparse") {
    my $pax = pax_record("SUN.holesdata", "0 4096");
    emit_entry("PaxHeaders/file", "x", $pax, undef, 0);
    emit_entry("file", "0", "", undef, 0);
} elsif ($mode eq "pax_mode") {
    my $pax = pax_record("SCHILY.mode", "0000755");
    emit_entry("PaxHeaders/file", "x", $pax, undef, 0);
    emit_entry("file", "0", "", undef, 0);
} elsif ($mode eq "flat_payload_mode") {
    emit_entry("bin/darkbloom", "0", "binary", undef, 0, "0000775\0");
} elsif ($mode eq "app_payload_mode") {
    emit_entry(
        "Darkbloom.app/Contents/MacOS/darkbloom-enclave",
        "0",
        "enclave",
        undef,
        0,
        "0000700\0",
    );
} elsif ($mode eq "metallib_payload_mode") {
    emit_entry("mlx.metallib", "0", "metal", undef, 0, "0000755\0");
} elsif ($mode eq "pax_overflow") {
    my $pax = pax_record("size", "999999999999999999999999999999999999");
    emit_entry("PaxHeaders/file", "x", $pax, undef, 0);
    emit_entry("file", "0", "", undef, 0);
} elsif ($mode eq "pax_path") {
    my $path = "Darkbloom.app/Contents/Resources/" . ("pax-name-" x 20);
    my $pax = pax_record("path", $path);
    emit_entry("PaxHeaders/file", "x", $pax, undef, 0);
    emit_entry("placeholder", "0", "resource", undef, 0);
} elsif ($mode eq "gnu_long") {
    my $path = "Darkbloom.app/Contents/Resources/" . ("long-name-" x 20);
    emit_entry("././\@LongLink", "L", "$path\0", undef, 0);
    emit_entry("placeholder", "0", "resource", undef, 0);
} elsif ($mode eq "aggregate") {
    emit_entry("first", "0", "12345678", undef, 0);
    emit_entry("second", "0", "abcdefgh", undef, 0);
} elsif ($mode eq "entries") {
    emit_entry("one", "0", "", undef, 0);
    emit_entry("two", "0", "", undef, 0);
    emit_entry("three", "0", "", undef, 0);
} elsif ($mode eq "bad_checksum") {
    my $header = tar_header("file", "0", 0, undef);
    substr($header, 0, 1, "g");
    print $header;
} elsif ($mode eq "trailing") {
    emit_entry("file", "0", "", undef, 0);
    print "\0" x (2 * $block_size);
    print "\1" x $block_size;
    exit(0);
} elsif ($mode eq "zero_trailer") {
    emit_entry("file", "0", "", undef, 0);
    print "\0" x (4 * $block_size);
    exit(0);
} else {
    die("unknown fixture mode: $mode\n");
}

print "\0" x (2 * $block_size);
PERL

make_fixture() {
    local mode=$1
    local output="$ROOT/$mode.tar.gz"
    /usr/bin/perl "$ROOT/make-tar.pl" "$mode" | gzip -c > "$output"
    printf '%s\n' "$output"
}

run_preflight() {
    local archive=$1
    shift
    for script in "$CANONICAL" "$EMBEDDED"; do
        bash "$script" --preflight-release-archive "$archive" "$@"
    done
}

expect_rejection() {
    local archive=$1
    local expected=$2
    shift 2
    for script in "$CANONICAL" "$EMBEDDED"; do
        local error_file="$ROOT/error-$RANDOM"
        if bash "$script" --preflight-release-archive \
            "$archive" "$@" 2>"$error_file"
        then
            echo "$script accepted unsafe archive $archive" >&2
            exit 1
        fi
        if ! grep -F "$expected" "$error_file" >/dev/null; then
            echo "$script rejected $archive for the wrong reason:" >&2
            sed -n '1,20p' "$error_file" >&2
            exit 1
        fi
    done
}

VALID_STAGE="$ROOT/valid-stage"
LONG_NAME=$(printf 'portable-name-%.0s' 1 2 3 4 5 6 7 8 9 10)
mkdir -p \
    "$VALID_STAGE/bin" \
    "$VALID_STAGE/Darkbloom.app/Contents/Resources"
printf 'binary\n' > "$VALID_STAGE/bin/darkbloom"
chmod 0755 "$VALID_STAGE/bin/darkbloom"
printf 'resource\n' \
    > "$VALID_STAGE/Darkbloom.app/Contents/Resources/$LONG_NAME"
VALID="$ROOT/valid.tar.gz"
tar czf "$VALID" -C "$VALID_STAGE" .
run_preflight "$VALID"
run_preflight "$(make_fixture pax_path)"
run_preflight "$(make_fixture gnu_long)"

MODE_PAYLOAD="$ROOT/mode-payload"
mkdir -p "$MODE_PAYLOAD"
printf 'binary\n' > "$MODE_PAYLOAD/darkbloom"
printf 'enclave\n' > "$MODE_PAYLOAD/darkbloom-enclave"
printf 'metallib\n' > "$MODE_PAYLOAD/mlx.metallib"
chmod 0755 "$MODE_PAYLOAD/darkbloom" "$MODE_PAYLOAD/darkbloom-enclave"
chmod 0644 "$MODE_PAYLOAD/mlx.metallib"
for script in "$CANONICAL" "$EMBEDDED"; do
    bash "$script" \
        --verify-release-payload-modes-test "$MODE_PAYLOAD" "Test payload"
    for mutation in \
        "darkbloom:775:755" \
        "darkbloom-enclave:700:755" \
        "mlx.metallib:755:644"
    do
        file=${mutation%%:*}
        remainder=${mutation#*:}
        bad_mode=${remainder%%:*}
        expected_mode=${remainder##*:}
        chmod "$bad_mode" "$MODE_PAYLOAD/$file"
        error_file="$ROOT/mode-error-$(basename "$script")-$file"
        if bash "$script" \
            --verify-release-payload-modes-test \
            "$MODE_PAYLOAD" "Test payload" 2>"$error_file"
        then
            echo "$script accepted mode $bad_mode for $file" >&2
            exit 1
        fi
        grep -F "expected 0${expected_mode}" "$error_file" >/dev/null
        chmod "$expected_mode" "$MODE_PAYLOAD/$file"
    done
done

SMALL_DOWNLOAD_SOURCE="$ROOT/small-download-source"
OVERSIZED_DOWNLOAD_SOURCE="$ROOT/oversized-download-source"
printf 'bounded download\n' > "$SMALL_DOWNLOAD_SOURCE"
/usr/bin/perl -e 'print "x" x 4096' > "$OVERSIZED_DOWNLOAD_SOURCE"
for script in "$CANONICAL" "$EMBEDDED"; do
    [ "$(bash "$script" --release-download-block-limit-test 1)" = "1" ]
    [ "$(bash "$script" --release-download-block-limit-test 1024)" = "1" ]
    [ "$(bash "$script" --release-download-block-limit-test 1025)" = "2" ]

    destination="$ROOT/download-$(basename "$script")"
    bash "$script" --download-release-archive-test \
        "file://$SMALL_DOWNLOAD_SOURCE" "$destination" 512
    cmp -s "$SMALL_DOWNLOAD_SOURCE" "$destination"
    rm -f "$destination"

    if bash "$script" --download-release-archive-test \
        "file://$OVERSIZED_DOWNLOAD_SOURCE" "$destination" 1024
    then
        echo "$script accepted an oversized streamed download" >&2
        exit 1
    fi
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        echo "$script retained an oversized partial download" >&2
        exit 1
    fi
done

LARGE=$(make_fixture large)
[ "$(wc -c < "$LARGE" | tr -d '[:space:]')" -lt 4096 ]
expect_rejection "$LARGE" "expanded-size limit"
expect_rejection "$(make_fixture negative)" "negative"
expect_rejection "$(make_fixture overflow)" "overflows int64"
expect_rejection "$(make_fixture duplicate)" "duplicate"
expect_rejection "$(make_fixture conflict)" "descends through file"
expect_rejection "$(make_fixture absolute)" "absolute"
expect_rejection "$(make_fixture traversal)" "parent traversal"
expect_rejection "$(make_fixture symlink)" "unsupported node type"
expect_rejection "$(make_fixture fifo)" "unsupported node type"
expect_rejection "$(make_fixture sparse)" "unsupported node type"
expect_rejection "$(make_fixture pax_sparse)" "unsupported sparse PAX metadata"
expect_rejection "$(make_fixture pax_sun_sparse)" "unsupported sparse PAX metadata"
expect_rejection "$(make_fixture pax_mode)" "unsupported PAX mode metadata"
expect_rejection "$(make_fixture flat_payload_mode)" "expected 0755"
expect_rejection "$(make_fixture app_payload_mode)" "expected 0755"
expect_rejection "$(make_fixture metallib_payload_mode)" "expected 0644"
expect_rejection "$(make_fixture pax_overflow)" "overflows"
expect_rejection "$(make_fixture aggregate)" "expanded-size limit" 2047 16384
expect_rejection "$(make_fixture zero_trailer)" "expanded-size limit" 1536 16384
expect_rejection "$(make_fixture entries)" "entry limit" 4294967296 2
expect_rejection "$(make_fixture bad_checksum)" "invalid checksum"
expect_rejection "$(make_fixture trailing)" "non-zero data"

# The installer itself must reject before creating any archive-controlled
# staging tree. Its lock/recovery directory may exist, but extraction may not.
REJECT_INSTALL="$ROOT/rejected-install"
REJECT_ERROR="$ROOT/rejected-install-error"
if bash "$CANONICAL" --install-bundle-test \
    "$LARGE" "$REJECT_INSTALL" "" "" 2>"$REJECT_ERROR"
then
    echo "installer accepted a large-header archive" >&2
    exit 1
fi
grep -F "expanded-size limit" "$REJECT_ERROR" >/dev/null
for path in "$REJECT_INSTALL"/.install-staging-*; do
    if [ -e "$path" ] || [ -L "$path" ]; then
        echo "installer created staging content before archive approval: $path" >&2
        exit 1
    fi
done

echo "release archive safety tests passed"
