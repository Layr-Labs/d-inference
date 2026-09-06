package api

import (
	"archive/tar"
	"bytes"
	"io"
	"strings"
	"testing"
)

// Keep this literal list independent of the implementation to pin all nine
// directories shared with Swift and the installer.
var nestedProviderDirectoryPathsForTest = []string{
	"Darkbloom.app",
	"Darkbloom.app/Contents",
	"Darkbloom.app/Contents/MacOS",
	"Darkbloom.app/Contents/Resources",
	"Darkbloom.app/Contents/Helpers",
	"Darkbloom.app/Contents/Helpers/DarkbloomProvider.app",
	"Darkbloom.app/Contents/Helpers/DarkbloomProvider.app/Contents",
	"Darkbloom.app/Contents/Helpers/DarkbloomProvider.app/Contents/MacOS",
	"Darkbloom.app/Contents/Helpers/DarkbloomProvider.app/Contents/Resources",
}

func nestedCLIAliasForArchiveTest() rawReleaseTarEntry {
	return rawReleaseTarEntry{
		name: releaseAppCLIAliasPath, typeflag: tar.TypeSymlink,
		linkname: releaseAppCLIAliasTarget, rawModeField: []byte("0000777\x00"),
	}
}

func nestedCLITargetForArchiveTest() rawReleaseTarEntry {
	return rawReleaseTarEntry{name: releaseNestedCLIPath, typeflag: tar.TypeReg, body: []byte("signed-cli")}
}

func TestReleaseArchiveAcceptsExactNestedCLIAlias(t *testing.T) {
	if releaseAppCLIAliasPath != "Darkbloom.app/Contents/MacOS/darkbloom" ||
		releaseNestedCLIPath != "Darkbloom.app/Contents/Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom" ||
		releaseAppCLIAliasTarget != "../Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom" {
		t.Fatal("nested CLI archive contract changed")
	}
	for _, reverse := range []bool{false, true} {
		for _, prefix := range []string{"", "./"} {
			alias, target := nestedCLIAliasForArchiveTest(), nestedCLITargetForArchiveTest()
			alias.name, target.name = prefix+alias.name, prefix+target.name
			entries := []rawReleaseTarEntry{alias, target}
			for _, directory := range nestedProviderDirectoryPathsForTest {
				entries = append(entries, rawReleaseTarEntry{name: prefix + directory + "/", typeflag: tar.TypeDir})
			}
			if reverse {
				for left, right := 0, len(entries)-1; left < right; left, right = left+1, right-1 {
					entries[left], entries[right] = entries[right], entries[left]
				}
			}
			var aliases, targets int
			err := validateReleaseArchive(bytes.NewReader(buildRawReleaseArchiveForTest(entries...)), defaultReleaseArchivePolicy,
				func(entry releaseArchiveEntry, reader io.Reader) error {
					switch entry.Path {
					case releaseAppCLIAliasPath:
						aliases++
						if entry.Kind != releaseArchiveSymlink || entry.Linkname != releaseAppCLIAliasTarget || entry.Size != 0 {
							t.Fatalf("incorrect alias exposed to collector: %+v", entry)
						}
					case releaseNestedCLIPath:
						targets++
						body, err := io.ReadAll(reader)
						if err != nil || string(body) != "signed-cli" || entry.Kind != releaseArchiveRegular {
							t.Fatalf("incorrect nested target: %+v body=%q err=%v", entry, body, err)
						}
					}
					return nil
				})
			if err != nil || aliases != 1 || targets != 1 {
				t.Fatalf("reverse=%t prefix=%q: aliases=%d targets=%d err=%v", reverse, prefix, aliases, targets, err)
			}
		}
	}
}

func TestReleaseArchiveRequiresExactNestedDirectoryHeaders(t *testing.T) {
	for _, directory := range nestedProviderDirectoryPathsForTest {
		for _, mutation := range []string{"missing", "miscased"} {
			t.Run(directory+"/"+mutation, func(t *testing.T) {
				entries := []rawReleaseTarEntry{nestedCLIAliasForArchiveTest(), nestedCLITargetForArchiveTest()}
				for _, path := range nestedProviderDirectoryPathsForTest {
					if path == directory {
						if mutation == "missing" {
							continue
						}
						path = strings.ToLower(path)
					}
					entries = append(entries, rawReleaseTarEntry{name: path + "/", typeflag: tar.TypeDir})
				}
				assertNestedArchiveRejected(t, "requires exact directory "+`"`+directory+`"`, entries...)
			})
		}
	}
}

func TestReleaseArchiveRejectsAlteredCLIAliasLinks(t *testing.T) {
	for name, target := range map[string]string{
		"empty":            "",
		"absolute":         "/" + releaseNestedCLIPath,
		"archive relative": releaseNestedCLIPath,
		"flat binary":      "../../../bin/darkbloom",
		"escape":           "../../../../tmp/darkbloom",
		"extra traversal":  "../Helpers/../Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom",
		"dot equivalent":   "./" + releaseAppCLIAliasTarget,
		"double slash":     strings.Replace(releaseAppCLIAliasTarget, "Helpers/", "Helpers//", 1),
		"trailing slash":   releaseAppCLIAliasTarget + "/",
		"case alias":       strings.Replace(releaseAppCLIAliasTarget, "DarkbloomProvider", "darkbloomprovider", 1),
		"backslash":        strings.ReplaceAll(releaseAppCLIAliasTarget, "/", "\\"),
		"other executable": releaseAppCLIAliasTarget + "-enclave",
		"NUL suffix":       releaseAppCLIAliasTarget + "\x00other",
		"newline":          releaseAppCLIAliasTarget + "\n",
	} {
		t.Run(name, func(t *testing.T) {
			alias := nestedCLIAliasForArchiveTest()
			alias.linkname = target
			assertNestedArchiveRejected(t, "must target exactly", alias, nestedCLITargetForArchiveTest())
		})
	}
	for _, path := range []string{"bin/darkbloom", releaseNestedCLIPath, "Darkbloom.app/Contents/MacOS/other", strings.ToLower(releaseAppCLIAliasPath)} {
		t.Run(path, func(t *testing.T) {
			alias := nestedCLIAliasForArchiveTest()
			alias.name = path
			assertNestedArchiveRejected(t, "unsupported node type", alias, nestedCLITargetForArchiveTest())
		})
	}
	alias := nestedCLIAliasForArchiveTest()
	alias.typeflag = tar.TypeLink
	assertNestedArchiveRejected(t, "unsupported node type", alias, nestedCLITargetForArchiveTest())
}

func TestReleaseArchiveRequiresRegularNestedCLITarget(t *testing.T) {
	alias := nestedCLIAliasForArchiveTest()
	assertNestedArchiveRejected(t, "requires regular target", alias)
	for _, kind := range []byte{tar.TypeDir, tar.TypeSymlink, tar.TypeLink, tar.TypeFifo} {
		target := nestedCLITargetForArchiveTest()
		target.typeflag, target.body = kind, nil
		want := "unsupported node type"
		if kind == tar.TypeDir {
			want = "requires regular target"
		}
		assertNestedArchiveRejected(t, want, alias, target)
	}
	target := nestedCLITargetForArchiveTest()
	target.name = strings.ToLower(target.name)
	assertNestedArchiveRejected(t, "requires regular target", alias, target)
}

func TestReleaseArchiveRejectsCLIAliasAncestorsAndDescendants(t *testing.T) {
	for _, path := range []string{
		"Darkbloom.app", "Darkbloom.app/Contents", "Darkbloom.app/Contents/MacOS",
		"Darkbloom.app/Contents/Helpers", releaseNestedAppPath,
		releaseNestedAppPath + "/Contents", releaseNestedAppPath + "/Contents/MacOS",
	} {
		for _, kind := range []byte{tar.TypeReg, tar.TypeSymlink} {
			for _, reverse := range []bool{false, true} {
				entries := []rawReleaseTarEntry{
					{name: path, typeflag: kind, linkname: "elsewhere"},
					nestedCLIAliasForArchiveTest(), nestedCLITargetForArchiveTest(),
				}
				if reverse {
					entries[0], entries[2] = entries[2], entries[0]
				}
				assertNestedArchiveRejected(t, "release archive", entries...)
			}
		}
	}
	for _, parent := range []string{releaseAppCLIAliasPath, releaseNestedCLIPath} {
		for _, reverse := range []bool{false, true} {
			entries := []rawReleaseTarEntry{nestedCLIAliasForArchiveTest(), nestedCLITargetForArchiveTest(),
				{name: parent + "/child", typeflag: tar.TypeReg}}
			if reverse {
				entries[0], entries[2] = entries[2], entries[0]
			}
			assertNestedArchiveRejected(t, "release archive", entries...)
		}
	}
}

func TestReleaseArchiveRejectsDuplicateCLIAliasAndTarget(t *testing.T) {
	for _, original := range []rawReleaseTarEntry{nestedCLIAliasForArchiveTest(), nestedCLITargetForArchiveTest()} {
		for _, name := range []string{original.name, "./" + original.name, strings.ToLower(original.name)} {
			duplicate := original
			duplicate.name = name
			// A regular entry colliding with an existing alias must also fail.
			duplicate.typeflag = tar.TypeReg
			assertNestedArchiveRejected(t, "duplicate or case-conflicting", nestedCLIAliasForArchiveTest(), nestedCLITargetForArchiveTest(), duplicate)
		}
	}
}

func TestReleaseArchiveRejectsCLIAliasSizeAndMetadataTricks(t *testing.T) {
	alias, target := nestedCLIAliasForArchiveTest(), nestedCLITargetForArchiveTest()
	trailing := alias
	trailing.name += "/"
	assertNestedArchiveRejected(t, "no trailing slash or payload", trailing, target)
	payload := alias
	payload.body = []byte("hidden")
	assertNestedArchiveRejected(t, "no trailing slash or payload", payload, target)
	paxSize := rawReleaseTarEntry{name: "PaxHeaders/alias", typeflag: tar.TypeXHeader, body: releasePAXRecordForTest("size", "1")}
	assertNestedArchiveRejected(t, "no trailing slash or payload", paxSize, alias, target)
	paxSize.body = releasePAXRecordForTest("size", "0")
	assertNestedArchiveRejected(t, "no trailing slash or payload", paxSize, payload, target)
	mode := alias
	mode.rawModeField = []byte("0004777\x00")
	assertNestedArchiveRejected(t, "portable permission bits", mode, target)
	for _, kind := range []byte{tar.TypeXHeader, tar.TypeXGlobalHeader} {
		metadata := rawReleaseTarEntry{name: "PaxHeaders/alias", typeflag: kind, body: releasePAXRecordForTest("linkpath", releaseAppCLIAliasTarget)}
		assertNestedArchiveRejected(t, "unsupported PAX link", metadata, alias, target)
	}
	longLink := rawReleaseTarEntry{name: "././@LongLink", typeflag: tar.TypeGNULongLink, body: []byte(releaseAppCLIAliasTarget + "\x00")}
	assertNestedArchiveRejected(t, "unsupported GNU long-link", longLink, alias, target)
	xattr := rawReleaseTarEntry{name: "PaxHeaders/alias", typeflag: tar.TypeXHeader, body: releasePAXRecordForTest("SCHILY.xattr.com.apple.cs.CodeSignature", "signature")}
	assertNestedArchiveRejected(t, "not attached to mlx.metallib", xattr, alias, target)
	paxPath := rawReleaseTarEntry{name: "PaxHeaders/alias", typeflag: tar.TypeXHeader, body: releasePAXRecordForTest("path", releaseAppCLIAliasPath+"/")}
	assertNestedArchiveRejected(t, "no trailing slash or payload", paxPath, alias, target)
	paxPath.body = releasePAXRecordForTest("path", "Darkbloom.app/Contents/MacOS/../darkbloom")
	assertNestedArchiveRejected(t, "parent traversal", paxPath, alias, target)
}

func TestReleaseArchiveAcceptsNestedMetallibSignatureMetadata(t *testing.T) {
	for _, key := range []string{"LIBARCHIVE.xattr.com.apple.cs.CodeSignature", "SCHILY.xattr.com.apple.cs.CodeDirectory"} {
		archive := buildRawReleaseArchiveForTest(
			rawReleaseTarEntry{name: "PaxHeaders/metallib", typeflag: tar.TypeXHeader, body: releasePAXRecordForTest(key, "signature")},
			rawReleaseTarEntry{name: releaseNestedAppPath + "/Contents/MacOS/mlx.metallib", typeflag: tar.TypeReg, body: []byte("metal")},
		)
		if err := validateReleaseArchive(bytes.NewReader(archive), defaultReleaseArchivePolicy, nil); err != nil {
			t.Fatal(err)
		}
	}
}

func assertNestedArchiveRejected(t *testing.T, want string, entries ...rawReleaseTarEntry) {
	t.Helper()
	err := validateReleaseArchive(bytes.NewReader(buildRawReleaseArchiveForTest(entries...)), defaultReleaseArchivePolicy, nil)
	if err == nil || !strings.Contains(err.Error(), want) {
		t.Fatalf("archive error = %v, want %q; entries=%+v", err, want, entries)
	}
}
