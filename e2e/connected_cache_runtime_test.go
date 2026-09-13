package e2e

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestConnectedRuntimeCopyOwnsUpdaterAndResourcePaths(t *testing.T) {
	source, root := t.TempDir(), t.TempDir()
	for name, body := range map[string]string{"darkbloom": "binary", "mlx.metallib": "metal", "other-daemon": "must not copy", "private.key": "must not copy"} {
		require.NoError(t, os.WriteFile(filepath.Join(source, name), []byte(body), 0700))
	}
	require.NoError(t, os.Mkdir(filepath.Join(source, "kernels.bundle"), 0700))
	require.NoError(t, os.WriteFile(filepath.Join(source, "kernels.bundle", "kernel.metal"), []byte("resource"), 0600))
	binary, err := stageConnectedRuntime(root, filepath.Join(source, "darkbloom"))
	require.NoError(t, err)
	expected, err := fileSHA256(filepath.Join(source, "darkbloom"))
	require.NoError(t, err)
	actual, err := fileSHA256(binary)
	require.NoError(t, err)
	require.Equal(t, expected, actual)
	require.FileExists(t, filepath.Join(filepath.Dir(binary), "kernels.bundle", "kernel.metal"))
	require.NoFileExists(t, filepath.Join(filepath.Dir(binary), "other-daemon"))
	require.NoFileExists(t, filepath.Join(filepath.Dir(binary), "private.key"))
	// Runtime-local mutation is isolated from the source package.
	require.NoError(t, os.WriteFile(binary, []byte("owned mutation"), 0700))
	unchanged, err := fileSHA256(filepath.Join(source, "darkbloom"))
	require.NoError(t, err)
	require.Equal(t, expected, unchanged)
}
