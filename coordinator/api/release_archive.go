package api

import (
	"bytes"
	"fmt"
	"io"
	"strings"
)

// Release archives are currently about 170 MiB compressed and comfortably
// below 1 GiB as a decompressed tar stream. These limits leave substantial
// room for signed app growth and duplicated flat verifier binaries while
// bounding disk, inode, parser-memory, and path-complexity exposure on every
// release consumer.
const (
	maxReleaseArtifactBytes         int64 = 2 << 30 // 2 GiB compressed
	maxReleaseArchiveExpandedBytes  int64 = 4 << 30 // 4 GiB decompressed tar stream
	maxReleaseArchiveEntries              = 16 * 1024
	maxReleaseArchivePathBytes            = 4 * 1024
	maxReleaseArchiveComponentBytes       = 255
	maxReleaseArchiveMetadataBytes  int64 = 1 << 20 // 1 MiB per PAX/long-name record

	releaseTarBlockSize = 512
)

type releaseArchivePolicy struct {
	maxExpandedBytes  int64
	maxEntries        int
	maxPathBytes      int
	maxComponentBytes int
	maxMetadataBytes  int64
}

var defaultReleaseArchivePolicy = releaseArchivePolicy{
	maxExpandedBytes:  maxReleaseArchiveExpandedBytes,
	maxEntries:        maxReleaseArchiveEntries,
	maxPathBytes:      maxReleaseArchivePathBytes,
	maxComponentBytes: maxReleaseArchiveComponentBytes,
	maxMetadataBytes:  maxReleaseArchiveMetadataBytes,
}

type releaseArchiveNodeKind uint8

const (
	releaseArchiveRegular releaseArchiveNodeKind = iota
	releaseArchiveDirectory
)

type releaseArchiveEntry struct {
	Path string
	Kind releaseArchiveNodeKind
	Size int64
	Mode int64
}

type releaseArchiveVisitor func(releaseArchiveEntry, io.Reader) error

type releaseArchivePendingMetadata struct {
	path                  *string
	size                  *int64
	codeSignatureMetadata bool
}

type releaseArchivePathTracker struct {
	nodes          map[string]releaseArchiveNodeKind
	hasDescendants map[string]struct{}
}

func newReleaseArchivePathTracker() *releaseArchivePathTracker {
	return &releaseArchivePathTracker{
		nodes:          make(map[string]releaseArchiveNodeKind),
		hasDescendants: make(map[string]struct{}),
	}
}

// validateReleaseArchive performs a header-only security decision before any
// caller extracts the tar. The visitor may inspect regular-file bytes while
// this pass streams through the archive; unread bytes are discarded.
func validateReleaseArchive(
	r io.Reader,
	policy releaseArchivePolicy,
	visitor releaseArchiveVisitor,
) error {
	if err := policy.validate(); err != nil {
		return err
	}

	tracker := newReleaseArchivePathTracker()
	var pending releaseArchivePendingMetadata
	var expandedBytes int64
	entryCount := 0

	for {
		header, err := readReleaseTarBlock(r)
		if err == io.EOF {
			return fmt.Errorf("release archive is missing the tar end marker")
		}
		if err != nil {
			return err
		}
		if err := addReleaseExpandedBytes(
			&expandedBytes,
			releaseTarBlockSize,
			policy,
		); err != nil {
			return err
		}
		if releaseTarBlockIsZero(header) {
			if err := validateReleaseTarEnd(
				r,
				&pending,
				&expandedBytes,
				policy,
			); err != nil {
				return err
			}
			return nil
		}

		entryCount++
		if entryCount > policy.maxEntries {
			return fmt.Errorf("release archive exceeds the %d-entry limit", policy.maxEntries)
		}
		if err := validateReleaseTarChecksum(header); err != nil {
			return err
		}

		headerPath, err := releaseTarHeaderPath(header)
		if err != nil {
			return err
		}
		if _, err := cleanReleaseArchivePath(headerPath, policy); err != nil {
			return fmt.Errorf("release archive header path %q: %w", headerPath, err)
		}

		headerSize, err := parseReleaseTarNumber(header[124:136], "entry size")
		if err != nil {
			return err
		}
		headerMode, err := parseReleaseTarNumber(header[100:108], "entry mode")
		if err != nil {
			return err
		}
		if headerMode > 0o777 {
			return fmt.Errorf("release archive entry mode exceeds portable permission bits")
		}
		typeflag := header[156]

		switch typeflag {
		case 'x':
			if headerSize > policy.maxMetadataBytes {
				return fmt.Errorf("release archive PAX metadata exceeds the %d-byte limit", policy.maxMetadataBytes)
			}
			if err := addReleaseTarPayloadBytes(&expandedBytes, headerSize, policy); err != nil {
				return err
			}
			payload, err := readReleaseTarPayload(r, headerSize)
			if err != nil {
				return fmt.Errorf("read release archive PAX metadata: %w", err)
			}
			attrs, err := parseReleasePAX(payload, policy)
			if err != nil {
				return err
			}
			if err := mergeReleasePendingMetadata(&pending, attrs); err != nil {
				return err
			}
			continue
		case 'g':
			if headerSize > policy.maxMetadataBytes {
				return fmt.Errorf("release archive global PAX metadata exceeds the %d-byte limit", policy.maxMetadataBytes)
			}
			if err := addReleaseTarPayloadBytes(&expandedBytes, headerSize, policy); err != nil {
				return err
			}
			payload, err := readReleaseTarPayload(r, headerSize)
			if err != nil {
				return fmt.Errorf("read release archive global PAX metadata: %w", err)
			}
			attrs, err := parseReleasePAX(payload, policy)
			if err != nil {
				return err
			}
			if attrs.path != nil ||
				attrs.size != nil ||
				attrs.codeSignatureMetadata {
				return fmt.Errorf("release archive global PAX metadata must not override path or size")
			}
			continue
		case 'L':
			if headerSize > policy.maxMetadataBytes {
				return fmt.Errorf("release archive GNU long-name metadata exceeds the %d-byte limit", policy.maxMetadataBytes)
			}
			if err := addReleaseTarPayloadBytes(&expandedBytes, headerSize, policy); err != nil {
				return err
			}
			payload, err := readReleaseTarPayload(r, headerSize)
			if err != nil {
				return fmt.Errorf("read release archive GNU long-name metadata: %w", err)
			}
			longName := string(bytes.TrimRight(payload, "\x00\n"))
			cleanName, err := cleanReleaseArchivePath(longName, policy)
			if err != nil {
				return fmt.Errorf("release archive GNU long name: %w", err)
			}
			if err := mergeReleasePendingPath(&pending, cleanName); err != nil {
				return err
			}
			continue
		case 'K':
			return fmt.Errorf("release archive contains unsupported GNU long-link metadata")
		}

		effectivePath, err := cleanReleaseArchivePath(headerPath, policy)
		if err != nil {
			return fmt.Errorf("release archive entry path %q: %w", headerPath, err)
		}
		if pending.path != nil {
			effectivePath = *pending.path
		}
		effectiveSize := headerSize
		if pending.size != nil {
			effectiveSize = *pending.size
		}
		hasCodeSignatureMetadata := pending.codeSignatureMetadata
		pending = releaseArchivePendingMetadata{}

		var kind releaseArchiveNodeKind
		switch typeflag {
		case 0, '0':
			kind = releaseArchiveRegular
		case '5':
			kind = releaseArchiveDirectory
			if effectiveSize != 0 {
				return fmt.Errorf("release archive directory %q has a non-zero size", effectivePath)
			}
		default:
			return fmt.Errorf(
				"release archive entry %q uses unsupported node type 0x%02x",
				effectivePath,
				typeflag,
			)
		}
		if hasCodeSignatureMetadata &&
			(kind != releaseArchiveRegular ||
				!releasePathAllowsCodeSignatureMetadata(effectivePath)) {
			return fmt.Errorf(
				"release archive code-signature metadata is not attached to mlx.metallib",
			)
		}

		if err := tracker.add(effectivePath, kind); err != nil {
			return err
		}
		if err := addReleaseTarPayloadBytes(&expandedBytes, effectiveSize, policy); err != nil {
			return err
		}

		entry := releaseArchiveEntry{
			Path: effectivePath,
			Kind: kind,
			Size: effectiveSize,
			Mode: headerMode,
		}
		if err := visitReleaseArchivePayload(r, entry, visitor); err != nil {
			return err
		}
	}
}

func (p releaseArchivePolicy) validate() error {
	if p.maxExpandedBytes < 0 || p.maxEntries <= 0 ||
		p.maxPathBytes <= 0 || p.maxComponentBytes <= 0 ||
		p.maxMetadataBytes < 0 {
		return fmt.Errorf("invalid release archive policy")
	}
	return nil
}

func readReleaseTarBlock(r io.Reader) ([]byte, error) {
	block := make([]byte, releaseTarBlockSize)
	n, err := io.ReadFull(r, block)
	if err == io.EOF && n == 0 {
		return nil, io.EOF
	}
	if err != nil {
		return nil, fmt.Errorf("release archive contains a truncated tar header: %w", err)
	}
	return block, nil
}

func releaseTarBlockIsZero(block []byte) bool {
	for _, value := range block {
		if value != 0 {
			return false
		}
	}
	return true
}

func validateReleaseTarEnd(
	r io.Reader,
	pending *releaseArchivePendingMetadata,
	expandedBytes *int64,
	policy releaseArchivePolicy,
) error {
	if pending.path != nil ||
		pending.size != nil ||
		pending.codeSignatureMetadata {
		return fmt.Errorf("release archive ends with dangling path or size metadata")
	}

	second, err := readReleaseTarBlock(r)
	if err != nil {
		return fmt.Errorf("release archive is missing the second tar end marker: %w", err)
	}
	if err := addReleaseExpandedBytes(
		expandedBytes,
		releaseTarBlockSize,
		policy,
	); err != nil {
		return err
	}
	if !releaseTarBlockIsZero(second) {
		return fmt.Errorf("release archive has an incomplete tar end marker")
	}

	buf := make([]byte, 32*1024)
	var trailingBytes int64
	for {
		n, readErr := r.Read(buf)
		if n > 0 {
			trailingBytes += int64(n)
			for _, value := range buf[:n] {
				if value != 0 {
					return fmt.Errorf("release archive contains non-zero data after the tar end marker")
				}
			}
			if err := addReleaseExpandedBytes(
				expandedBytes,
				int64(n),
				policy,
			); err != nil {
				return err
			}
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			return fmt.Errorf("read release archive trailer: %w", readErr)
		}
		if n == 0 {
			return fmt.Errorf("read release archive trailer made no progress")
		}
	}
	if trailingBytes%releaseTarBlockSize != 0 {
		return fmt.Errorf("release archive trailer is not block-aligned")
	}
	return nil
}

func validateReleaseTarChecksum(header []byte) error {
	stored, err := parseReleaseTarOctal(header[148:156], "header checksum")
	if err != nil {
		return err
	}

	var sum int64
	for index, value := range header {
		if index >= 148 && index < 156 {
			sum += int64(' ')
		} else {
			sum += int64(value)
		}
	}
	if stored != sum {
		return fmt.Errorf("release archive contains a tar header with an invalid checksum")
	}
	return nil
}

func releaseTarHeaderPath(header []byte) (string, error) {
	name, err := releaseTarString(header[0:100])
	if err != nil {
		return "", fmt.Errorf("release archive contains an invalid tar name field: %w", err)
	}
	prefix, err := releaseTarString(header[345:500])
	if err != nil {
		return "", fmt.Errorf("release archive contains an invalid tar prefix field: %w", err)
	}
	if prefix == "" {
		return name, nil
	}
	if !bytes.HasPrefix(header[257:263], []byte("ustar")) {
		return "", fmt.Errorf("release archive uses a tar prefix without a USTAR header")
	}
	return prefix + "/" + name, nil
}

func releaseTarString(field []byte) (string, error) {
	nul := bytes.IndexByte(field, 0)
	if nul < 0 {
		return string(field), nil
	}
	for _, value := range field[nul+1:] {
		if value != 0 {
			return "", fmt.Errorf("non-zero padding after NUL")
		}
	}
	return string(field[:nul]), nil
}

func parseReleaseTarNumber(field []byte, label string) (int64, error) {
	if len(field) == 0 {
		return 0, fmt.Errorf("release archive %s is empty", label)
	}
	if field[0]&0x80 == 0 {
		return parseReleaseTarOctal(field, label)
	}

	// POSIX/GNU base-256 uses the high bit as an encoding marker and the
	// remaining bits as a signed two's-complement integer. Archive sizes are
	// never negative, and values beyond int64 cannot be represented safely by
	// all three release consumers.
	if field[0]&0x40 != 0 {
		return 0, fmt.Errorf("release archive %s is negative", label)
	}
	value := int64(field[0] & 0x3f)
	for _, digit := range field[1:] {
		if value > (int64(^uint64(0)>>1)-int64(digit))/256 {
			return 0, fmt.Errorf("release archive %s overflows int64", label)
		}
		value = value*256 + int64(digit)
	}
	return value, nil
}

func parseReleaseTarOctal(field []byte, label string) (int64, error) {
	start := 0
	for start < len(field) && (field[start] == 0 || field[start] == ' ') {
		start++
	}
	end := len(field)
	for end > start && (field[end-1] == 0 || field[end-1] == ' ') {
		end--
	}
	if start == end {
		return 0, nil
	}

	var value int64
	for _, digit := range field[start:end] {
		if digit < '0' || digit > '7' {
			return 0, fmt.Errorf("release archive %s is not valid octal", label)
		}
		value = value*8 + int64(digit-'0')
	}
	return value, nil
}

func parseReleasePAX(
	payload []byte,
	policy releaseArchivePolicy,
) (releaseArchivePendingMetadata, error) {
	var attrs releaseArchivePendingMetadata
	seen := make(map[string]struct{})

	for offset := 0; offset < len(payload); {
		spaceOffset := bytes.IndexByte(payload[offset:], ' ')
		if spaceOffset <= 0 {
			return attrs, fmt.Errorf("release archive contains malformed PAX metadata")
		}
		spaceOffset += offset

		recordLength, err := parseReleaseDecimal(
			payload[offset:spaceOffset],
			int64(len(payload)-offset),
			"PAX record length",
		)
		if err != nil {
			return attrs, err
		}
		if recordLength <= int64(spaceOffset-offset+1) ||
			recordLength > int64(len(payload)-offset) {
			return attrs, fmt.Errorf("release archive contains an invalid PAX record length")
		}
		recordEnd := offset + int(recordLength)
		if payload[recordEnd-1] != '\n' {
			return attrs, fmt.Errorf("release archive PAX record is missing its newline terminator")
		}

		body := payload[spaceOffset+1 : recordEnd-1]
		equals := bytes.IndexByte(body, '=')
		if equals <= 0 {
			return attrs, fmt.Errorf("release archive contains a malformed PAX key/value record")
		}
		keyBytes := body[:equals]
		for _, value := range keyBytes {
			if value < 0x21 || value > 0x7e || value == '=' {
				return attrs, fmt.Errorf("release archive contains an invalid PAX key")
			}
		}
		key := string(keyBytes)
		if _, duplicate := seen[key]; duplicate {
			return attrs, fmt.Errorf("release archive repeats PAX key %q", key)
		}
		seen[key] = struct{}{}
		value := body[equals+1:]

		if releasePAXKeyIsSparse(key) {
			return attrs, fmt.Errorf("release archive contains unsupported sparse PAX metadata %q", key)
		}
		switch key {
		case "path":
			cleanPath, err := cleanReleaseArchivePath(string(value), policy)
			if err != nil {
				return attrs, fmt.Errorf("release archive PAX path: %w", err)
			}
			attrs.path = &cleanPath
		case "linkpath":
			return attrs, fmt.Errorf("release archive contains unsupported PAX link metadata")
		case "size":
			size, err := parseReleaseDecimal(value, int64(^uint64(0)>>1), "PAX size")
			if err != nil {
				return attrs, err
			}
			attrs.size = &size
		case "mtime":
			if err := validateReleasePAXTimestamp(value); err != nil {
				return attrs, err
			}
		case "SCHILY.filetype":
			return attrs, fmt.Errorf("release archive contains unsupported PAX file-type metadata")
		case "SCHILY.mode":
			return attrs, fmt.Errorf("release archive contains unsupported PAX mode metadata")
		default:
			if releasePAXKeyIsStrippedCodeSignatureMetadata(key) {
				attrs.codeSignatureMetadata = true
				break
			}
			return attrs, fmt.Errorf(
				"release archive contains unsupported PAX metadata key %q",
				key,
			)
		}

		offset = recordEnd
	}
	return attrs, nil
}

func releasePAXKeyIsSparse(key string) bool {
	return key == "GNU.sparse" ||
		strings.HasPrefix(key, "GNU.sparse.") ||
		key == "SCHILY.realsize" ||
		key == "SUN.holesdata" ||
		strings.HasPrefix(key, "LIBARCHIVE.sparse")
}

func releasePAXKeyIsStrippedCodeSignatureMetadata(key string) bool {
	switch key {
	case "LIBARCHIVE.xattr.com.apple.cs.CodeDirectory",
		"LIBARCHIVE.xattr.com.apple.cs.CodeRequirements",
		"LIBARCHIVE.xattr.com.apple.cs.CodeSignature",
		"SCHILY.xattr.com.apple.cs.CodeDirectory",
		"SCHILY.xattr.com.apple.cs.CodeRequirements",
		"SCHILY.xattr.com.apple.cs.CodeSignature":
		return true
	default:
		return false
	}
}

func releasePathAllowsCodeSignatureMetadata(path string) bool {
	switch path {
	case "bin/mlx.metallib",
		"mlx.metallib",
		"Darkbloom.app/Contents/MacOS/mlx.metallib":
		return true
	default:
		return false
	}
}

func validateReleasePAXTimestamp(raw []byte) error {
	parts := bytes.Split(raw, []byte{'.'})
	if len(parts) > 2 {
		return fmt.Errorf("release archive PAX mtime is not a canonical timestamp")
	}
	if _, err := parseReleaseDecimal(
		parts[0],
		int64(^uint64(0)>>1),
		"PAX mtime seconds",
	); err != nil {
		return err
	}
	if len(parts) == 1 {
		return nil
	}
	fraction := parts[1]
	if len(fraction) == 0 || len(fraction) > 9 {
		return fmt.Errorf("release archive PAX mtime has invalid fractional precision")
	}
	for _, digit := range fraction {
		if digit < '0' || digit > '9' {
			return fmt.Errorf("release archive PAX mtime fraction is not decimal")
		}
	}
	return nil
}

func parseReleaseDecimal(raw []byte, limit int64, label string) (int64, error) {
	if len(raw) == 0 {
		return 0, fmt.Errorf("release archive %s is empty", label)
	}
	var value int64
	for _, digit := range raw {
		if digit < '0' || digit > '9' {
			return 0, fmt.Errorf("release archive %s is not an unsigned decimal integer", label)
		}
		numeric := int64(digit - '0')
		if value > (limit-numeric)/10 {
			return 0, fmt.Errorf("release archive %s overflows its supported range", label)
		}
		value = value*10 + numeric
	}
	return value, nil
}

func mergeReleasePendingMetadata(
	pending *releaseArchivePendingMetadata,
	attrs releaseArchivePendingMetadata,
) error {
	if attrs.path != nil {
		if err := mergeReleasePendingPath(pending, *attrs.path); err != nil {
			return err
		}
	}
	if attrs.size != nil {
		if pending.size != nil && *pending.size != *attrs.size {
			return fmt.Errorf("release archive contains conflicting size metadata")
		}
		size := *attrs.size
		pending.size = &size
	}
	pending.codeSignatureMetadata =
		pending.codeSignatureMetadata || attrs.codeSignatureMetadata
	return nil
}

func mergeReleasePendingPath(
	pending *releaseArchivePendingMetadata,
	cleanPath string,
) error {
	if pending.path != nil && *pending.path != cleanPath {
		return fmt.Errorf("release archive contains conflicting path metadata")
	}
	pathCopy := cleanPath
	pending.path = &pathCopy
	return nil
}

func cleanReleaseArchivePath(
	raw string,
	policy releaseArchivePolicy,
) (string, error) {
	if raw == "" {
		return "", fmt.Errorf("path is empty")
	}
	if len(raw) > policy.maxPathBytes {
		return "", fmt.Errorf("path exceeds the %d-byte limit", policy.maxPathBytes)
	}
	if strings.HasPrefix(raw, "/") {
		return "", fmt.Errorf("path is absolute")
	}

	for index := 0; index < len(raw); index++ {
		value := raw[index]
		if value < 0x20 || value > 0x7e {
			return "", fmt.Errorf("path contains non-portable bytes")
		}
		if value == '\\' {
			return "", fmt.Errorf("path contains a backslash")
		}
	}

	parts := make([]string, 0, strings.Count(raw, "/")+1)
	for _, part := range strings.Split(raw, "/") {
		switch part {
		case "", ".":
			continue
		case "..":
			return "", fmt.Errorf("path contains parent traversal")
		}
		if len(part) > policy.maxComponentBytes {
			return "", fmt.Errorf("path component exceeds the %d-byte limit", policy.maxComponentBytes)
		}
		parts = append(parts, part)
	}
	if len(parts) == 0 {
		return ".", nil
	}
	cleaned := strings.Join(parts, "/")
	if len(cleaned) > policy.maxPathBytes {
		return "", fmt.Errorf("normalized path exceeds the %d-byte limit", policy.maxPathBytes)
	}
	return cleaned, nil
}

func foldReleaseArchivePath(path string) string {
	var folded strings.Builder
	folded.Grow(len(path))
	for index := 0; index < len(path); index++ {
		value := path[index]
		if value >= 'A' && value <= 'Z' {
			value += 'a' - 'A'
		}
		folded.WriteByte(value)
	}
	return folded.String()
}

func (tracker *releaseArchivePathTracker) add(
	path string,
	kind releaseArchiveNodeKind,
) error {
	key := foldReleaseArchivePath(path)
	if key == "." && kind != releaseArchiveDirectory {
		return fmt.Errorf("release archive root entry must be a directory")
	}
	if _, duplicate := tracker.nodes[key]; duplicate {
		return fmt.Errorf("release archive contains duplicate or case-conflicting path %q", path)
	}
	if kind == releaseArchiveRegular {
		if _, hasChildren := tracker.hasDescendants[key]; hasChildren {
			return fmt.Errorf("release archive file %q conflicts with descendant entries", path)
		}
	}

	if key != "." {
		parts := strings.Split(key, "/")
		for end := 1; end < len(parts); end++ {
			ancestor := strings.Join(parts[:end], "/")
			if existing, ok := tracker.nodes[ancestor]; ok &&
				existing != releaseArchiveDirectory {
				return fmt.Errorf("release archive path %q descends through file %q", path, ancestor)
			}
			tracker.hasDescendants[ancestor] = struct{}{}
		}
	}
	tracker.nodes[key] = kind
	return nil
}

func addReleaseExpandedBytes(
	total *int64,
	size int64,
	policy releaseArchivePolicy,
) error {
	if size < 0 {
		return fmt.Errorf("release archive entry size is negative")
	}
	if size > policy.maxExpandedBytes || *total > policy.maxExpandedBytes-size {
		return fmt.Errorf(
			"release archive exceeds the %d-byte expanded-size limit",
			policy.maxExpandedBytes,
		)
	}
	*total += size
	return nil
}

func addReleaseTarPayloadBytes(
	total *int64,
	size int64,
	policy releaseArchivePolicy,
) error {
	if size < 0 {
		return fmt.Errorf("release archive entry size is negative")
	}
	padding := (releaseTarBlockSize - size%releaseTarBlockSize) %
		releaseTarBlockSize
	if size > int64(^uint64(0)>>1)-padding {
		return fmt.Errorf("release archive entry size overflows int64")
	}
	return addReleaseExpandedBytes(total, size+padding, policy)
}

func readReleaseTarPayload(r io.Reader, size int64) ([]byte, error) {
	payload := make([]byte, int(size))
	if _, err := io.ReadFull(r, payload); err != nil {
		return nil, err
	}
	if err := skipReleaseTarPadding(r, size); err != nil {
		return nil, err
	}
	return payload, nil
}

func visitReleaseArchivePayload(
	r io.Reader,
	entry releaseArchiveEntry,
	visitor releaseArchiveVisitor,
) error {
	limited := &io.LimitedReader{R: r, N: entry.Size}
	if visitor != nil {
		if err := visitor(entry, limited); err != nil {
			return err
		}
	}
	if limited.N > 0 {
		if _, err := io.CopyN(io.Discard, limited, limited.N); err != nil {
			return fmt.Errorf("release archive entry %q is truncated: %w", entry.Path, err)
		}
	}
	if err := skipReleaseTarPadding(r, entry.Size); err != nil {
		return fmt.Errorf("release archive entry %q has truncated padding: %w", entry.Path, err)
	}
	return nil
}

func skipReleaseTarPadding(r io.Reader, size int64) error {
	padding := (releaseTarBlockSize - size%releaseTarBlockSize) % releaseTarBlockSize
	if padding == 0 {
		return nil
	}
	_, err := io.CopyN(io.Discard, r, padding)
	return err
}
