package api

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestReleaseRegistrationRejectsMissingOrMiscasedNestedDirectories(t *testing.T) {
	for _, directory := range nestedProviderDirectoryPathsForTest {
		for _, mutation := range []string{"missing", "miscased"} {
			t.Run(directory+"/"+mutation, func(t *testing.T) {
				fixture := newReleaseBundleTestFixture(releaseBundleTestNestedApp, []byte("signed-provider"))
				if mutation == "missing" {
					fixture.remove(directory + "/")
				} else {
					fixture.entry(t, directory+"/").name = strings.ToLower(directory) + "/"
				}
				assertReleaseRegistrationRejected(t,
					registerReleaseArtifactForTest(t, fixture.build(t), nil),
					"requires exact directory "+`"`+directory+`"`)
			})
		}
	}
}

func TestReleaseRegistrationPreservesLegacyArchivesWithoutDirectoryHeaders(t *testing.T) {
	for _, layout := range []releaseBundleTestLayout{releaseBundleTestLegacy, releaseBundleTestLegacyApp, releaseBundleTestApp} {
		t.Run(fmt.Sprint(layout), func(t *testing.T) {
			fixture := newReleaseBundleTestFixture(layout, []byte("signed-legacy-provider"))
			files := fixture.entries[:0]
			for _, entry := range fixture.entries {
				if entry.typeflag != tar.TypeDir {
					files = append(files, entry)
				}
			}
			fixture.entries = files
			result := registerReleaseArtifactForTest(t, fixture.build(t), nil)
			if result.status != http.StatusOK || len(result.releases) != 1 {
				t.Fatalf("legacy archive without directory headers: %d %s", result.status, result.body)
			}
		})
	}
}

func TestReleaseRegistrationRejectsIncompleteNestedApp(t *testing.T) {
	paths := []string{
		releaseNestedCLIPath,
		releaseNestedAppPayloadSpecs[1].path,
		releaseNestedAppPayloadSpecs[2].path,
		releaseNestedAppBaseFileSpecs[0].path,
		releaseNestedAppBaseFileSpecs[1].path,
	}
	for _, path := range paths {
		for _, mutation := range []string{"missing", "empty", "mode", "directory", "symlink", "hardlink", "duplicate", "case duplicate"} {
			t.Run(path+"/"+mutation, func(t *testing.T) {
				fixture := newReleaseBundleTestFixture(releaseBundleTestNestedApp, []byte("signed-provider"))
				entry := fixture.entry(t, path)
				want := path
				switch mutation {
				case "missing":
					fixture.remove(path)
				case "empty":
					entry.body = nil
				case "mode":
					entry.mode = 0o600
				case "directory":
					entry.typeflag, entry.body = tar.TypeDir, nil
				case "symlink":
					entry.typeflag, entry.linkname, entry.body = tar.TypeSymlink, "../../../bin/darkbloom", nil
				case "hardlink":
					entry.typeflag, entry.linkname, entry.body = tar.TypeLink, "bin/darkbloom", nil
				case "duplicate", "case duplicate":
					fixture.duplicate(t, path)
					if mutation == "case duplicate" {
						fixture.entries[len(fixture.entries)-1].name = strings.ToLower(path)
					}
					want = "duplicate or case-conflicting"
				}
				assertReleaseRegistrationRejected(t, registerReleaseArtifactForTest(t, fixture.build(t), nil), want)
			})
		}
	}
}

func TestReleaseRegistrationRejectsNestedPayloadCopyMismatch(t *testing.T) {
	for _, specs := range [][]releasePayloadSpec{releaseNestedAppPayloadSpecs, releaseAppPayloadSpecs[1:]} {
		for _, spec := range specs {
			t.Run(spec.path, func(t *testing.T) {
				fixture := newReleaseBundleTestFixture(releaseBundleTestNestedApp, []byte("signed-provider"))
				fixture.entry(t, spec.path).body = []byte("different-signed-bytes")
				want := "copies of " + releasePayloadKindName(spec.kind) + " do not match"
				assertReleaseRegistrationRejected(t, registerReleaseArtifactForTest(t, fixture.build(t), nil), want)
			})
		}
	}
	for _, field := range []string{"binary_hash", "metallib_hash"} {
		t.Run(field, func(t *testing.T) {
			fixture := newReleaseBundleTestFixture(releaseBundleTestNestedApp, []byte("signed-provider"))
			result := registerReleaseArtifactForTest(t, fixture.build(t), func(metadata map[string]string) {
				metadata[field] = strings.Repeat("a", 64)
			})
			assertReleaseRegistrationRejected(t, result, field+" does not match")
		})
	}
}

func TestReleaseRegistrationRejectsNestedAppWithoutAliasOrGUI(t *testing.T) {
	for _, mutation := range []string{"missing alias", "regular outer CLI", "missing GUI", "missing nested app"} {
		t.Run(mutation, func(t *testing.T) {
			fixture := newReleaseBundleTestFixture(releaseBundleTestNestedApp, []byte("signed-provider"))
			want := "requires the exact outer CLI alias"
			switch mutation {
			case "missing alias":
				fixture.remove(releaseAppCLIAliasPath)
			case "regular outer CLI":
				entry := fixture.entry(t, releaseAppCLIAliasPath)
				entry.typeflag, entry.mode, entry.linkname = tar.TypeReg, releaseExecutableMode, ""
				entry.body = []byte("signed-provider")
			case "missing GUI":
				for _, spec := range releaseGUIAppFileSpecs {
					fixture.remove(spec.path)
				}
				want = releaseGUIAppFileSpecs[0].path
			case "missing nested app":
				for index := len(fixture.entries) - 1; index >= 0; index-- {
					if strings.HasPrefix(fixture.entries[index].name, releaseNestedAppPath+"/") {
						fixture.remove(fixture.entries[index].name)
					}
				}
				want = "requires regular target"
			}
			assertReleaseRegistrationRejected(t, registerReleaseArtifactForTest(t, fixture.build(t), nil), want)
		})
	}
}

func TestReleaseRegistrationChecksNestedAndGUIPlistIdentity(t *testing.T) {
	for _, path := range []string{releaseNestedAppBaseFileSpecs[0].path, releaseLegacyAppBaseFileSpecs[0].path} {
		for _, field := range []string{"CFBundleExecutable", "CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString", "CFBundlePackageType"} {
			t.Run(path+"/"+field, func(t *testing.T) {
				fixture := newReleaseBundleTestFixture(releaseBundleTestNestedApp, []byte("signed-provider"))
				entry := fixture.entry(t, path)
				key := "<key>" + field + "</key><string>"
				entry.body = bytes.Replace(entry.body, []byte(key), []byte(key+"wrong-"), 1)
				assertReleaseRegistrationRejected(t, registerReleaseArtifactForTest(t, fixture.build(t), nil), "Info.plist "+field)
			})
		}
	}
}

func TestReleaseRegistrationRejectsAmbiguousNestedPlist(t *testing.T) {
	const identifier = "<key>CFBundleIdentifier</key><string>io.darkbloom.provider</string>"
	for _, mutation := range []string{"non XML", "missing identity", "duplicate identity", "wrong value type", "nested identity", "nested string", "duplicate dictionary", "trailing document", "truncated XML", "namespace", "oversized"} {
		t.Run(mutation, func(t *testing.T) {
			fixture := newReleaseBundleTestFixture(releaseBundleTestNestedApp, []byte("signed-provider"))
			entry := fixture.entry(t, releaseNestedAppBaseFileSpecs[0].path)
			body := string(entry.body)
			switch mutation {
			case "non XML":
				body = "opaque legacy plist cannot claim nested identity"
			case "missing identity":
				body = strings.Replace(body, identifier, "", 1)
			case "duplicate identity":
				body = strings.Replace(body, identifier, identifier+identifier, 1)
			case "wrong value type":
				body = strings.Replace(body, identifier, "<key>CFBundleIdentifier</key><data>io.darkbloom.provider</data>", 1)
			case "nested identity":
				body = strings.Replace(body, identifier, "<key>Ignored</key><dict>"+identifier+"</dict>", 1)
			case "nested string":
				body = strings.Replace(body, "<string>io.darkbloom.provider</string>", "<string>io.darkbloom.provider<string>other</string></string>", 1)
			case "duplicate dictionary":
				body = strings.Replace(body, "</plist>", "<dict/> </plist>", 1)
			case "trailing document":
				body += "<plist><dict/></plist>"
			case "truncated XML":
				body = strings.TrimSuffix(body, "</plist>")
			case "namespace":
				body = strings.Replace(body, `<plist version="1.0">`, `<plist version="1.0" xmlns="urn:other">`, 1)
			case "oversized":
				body += strings.Repeat(" ", int(maxReleasePlistBytes))
			}
			entry.body = []byte(body)
			assertReleaseRegistrationRejected(t, registerReleaseArtifactForTest(t, fixture.build(t), nil), releaseNestedAppBaseFileSpecs[0].path)
		})
	}
}

func TestReleaseRegistrationValidatesNestedRuntimeResources(t *testing.T) {
	binary := []byte("provider:" + releaseFanCapabilityMarker + ":" + releasePagedCapabilityMarker)
	newFixture := func() *releaseBundleTestFixture {
		fixture := newReleaseBundleTestFixture(releaseBundleTestNestedApp, binary)
		for _, specs := range [][]releaseArtifactFileSpec{
			releaseFanCapabilityFileSpecs, releasePagedCapabilityFileSpecs,
			releaseNestedPagedCapabilityFileSpecs,
		} {
			fixture.addArtifactFiles(specs)
		}
		return fixture
	}
	result := registerReleaseArtifactForTest(t, newFixture().build(t), nil)
	if result.status != http.StatusOK || len(result.releases) != 1 {
		t.Fatalf("valid nested runtime resources: %d %s", result.status, result.body)
	}
	stored := result.releases[0]
	if stored.HasApp == nil || !*stored.HasApp || stored.HasFanHelper == nil || !*stored.HasFanHelper || stored.HasPagedKernel == nil || !*stored.HasPagedKernel {
		t.Fatalf("missing nested runtime capabilities: %+v", stored)
	}
	for _, specs := range [][]releaseArtifactFileSpec{releaseFanCapabilityFileSpecs, releaseNestedPagedCapabilityFileSpecs} {
		for _, spec := range specs {
			for _, mutation := range []string{"missing", "symlink", "empty", "mode", "contents"} {
				if mutation == "contents" && spec.exactContents == "" {
					continue
				}
				t.Run(spec.path+"/"+mutation, func(t *testing.T) {
					fixture := newFixture()
					entry := fixture.entry(t, spec.path)
					want := spec.path
					switch mutation {
					case "missing":
						fixture.remove(spec.path)
						want = "capability code and artifact files must be present together"
					case "symlink":
						entry.typeflag, entry.linkname, entry.body = tar.TypeSymlink, "other", nil
					case "empty":
						entry.body = nil
					case "mode":
						entry.mode = 0o600
					case "contents":
						entry.body = []byte("0\n")
					}
					assertReleaseRegistrationRejected(t, registerReleaseArtifactForTest(t, fixture.build(t), nil), want)
				})
			}
		}
	}
}

func TestReleaseNestedPayloadBoundsCheckedBeforeRead(t *testing.T) {
	for _, spec := range releaseNestedAppPayloadSpecs {
		t.Run(spec.path, func(t *testing.T) {
			archive := buildRawReleaseArchiveForTest(rawReleaseTarEntry{
				name: spec.path, typeflag: tar.TypeReg,
				rawModeField:   []byte(fmt.Sprintf("%07o\x00", spec.mode)),
				rawSizeField:   []byte(fmt.Sprintf("%011o\x00", maxReleasePayloadBytes+1)),
				omitBodyAndPad: true,
			})
			collector := newReleasePayloadCollector()
			err := validateReleaseArchive(bytes.NewReader(archive), defaultReleaseArchivePolicy, collector.visit)
			if err == nil || !strings.Contains(err.Error(), "exceeds the") || !strings.Contains(err.Error(), spec.path) {
				t.Fatalf("oversized nested payload error = %v", err)
			}
			// The collector must hash all bytes of a real target, not the alias.
			err = newReleasePayloadCollector().visit(releaseArchiveEntry{
				Path: spec.path, Kind: releaseArchiveRegular, Size: 10, Mode: spec.mode,
			}, io.LimitReader(strings.NewReader("short"), 10))
			if err == nil || !strings.Contains(err.Error(), "is truncated") {
				t.Fatalf("truncated nested payload error = %v", err)
			}
		})
	}
}

func TestReleaseRegistrationPreservesOpaqueLegacyPlists(t *testing.T) {
	for _, layout := range []releaseBundleTestLayout{releaseBundleTestLegacyApp, releaseBundleTestApp} {
		fixture := newReleaseBundleTestFixture(layout, []byte("signed-legacy-provider"))
		fixture.entry(t, releaseLegacyAppBaseFileSpecs[0].path).body = bytes.Repeat([]byte("x"), int(maxReleasePlistBytes+1))
		result := registerReleaseArtifactForTest(t, fixture.build(t), nil)
		if result.status != http.StatusOK || len(result.releases) != 1 {
			t.Fatalf("legacy layout %d gained nested plist restrictions: %d %s", layout, result.status, result.body)
		}
	}
}

func TestReleaseRegistrationRejectsDifferentNestedProvisioningProfile(t *testing.T) {
	fixture := newReleaseBundleTestFixture(releaseBundleTestNestedApp, []byte("signed-provider"))
	fixture.entry(t, releaseNestedAppBaseFileSpecs[1].path).body = []byte("different-profile")
	assertReleaseRegistrationRejected(t, registerReleaseArtifactForTest(t, fixture.build(t), nil), "provisioning profiles differ")
}

func TestReleaseNestedLayoutHasNoMinimumVersion(t *testing.T) {
	for _, layout := range []releaseBundleTestLayout{releaseBundleTestLegacyApp, releaseBundleTestApp, releaseBundleTestNestedApp} {
		for _, version := range []string{"0.0.1", "1.0.0", "99.0.0"} {
			t.Run(fmt.Sprintf("layout=%d/version=%s", layout, version), func(t *testing.T) {
				fixture := newReleaseBundleTestFixture(layout, []byte("signed-provider"))
				if layout == releaseBundleTestNestedApp {
					for _, path := range []string{releaseLegacyAppBaseFileSpecs[0].path, releaseNestedAppBaseFileSpecs[0].path} {
						entry := fixture.entry(t, path)
						entry.body = bytes.ReplaceAll(entry.body, []byte("<string>1.0.0</string>"), []byte("<string>"+version+"</string>"))
					}
				}
				artifact := fixture.build(t)
				gz, err := gzip.NewReader(bytes.NewReader(artifact.bytes))
				if err != nil {
					t.Fatal(err)
				}
				defer gz.Close()
				collector := newReleasePayloadCollector()
				if err := validateReleaseArchive(gz, defaultReleaseArchivePolicy, collector.visit); err != nil {
					t.Fatal(err)
				}
				if err := collector.validate(&store.Release{Version: version, BinaryHash: artifact.binaryHash, MetallibHash: artifact.metallibHash}); err != nil {
					t.Fatalf("layout unexpectedly version-gated: %v", err)
				}
			})
		}
	}
}
