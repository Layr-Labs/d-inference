package artifacts

import (
	"fmt"
	"io/fs"
	"os"
	"slices"
)

func makeTreeContentsReadOnly(root *os.Root) error {
	var directories []string
	if err := fs.WalkDir(root.FS(), ".", func(name string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return ErrArtifactIntegrity
		}
		if entry.IsDir() {
			directories = append(directories, name)
		}
		return nil
	}); err != nil {
		return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
	}
	slices.Reverse(directories)
	for _, name := range directories {
		if name == "." {
			continue
		}
		directory, err := secureOpenDirectory(root, name, false, 0)
		if err != nil {
			return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
		}
		if err := directory.Chmod(0o500); err != nil {
			_ = directory.Close()
			return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
		}
		if err := directory.Sync(); err != nil {
			_ = directory.Close()
			return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
		}
		if err := directory.Close(); err != nil {
			return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
		}
	}
	return rejectSymlinks(root)
}

func MakeTreeWritable(root *os.Root) error {
	var directories []string
	if err := fs.WalkDir(root.FS(), ".", func(name string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			directories = append(directories, name)
		}
		return nil
	}); err != nil {
		return err
	}
	for _, name := range directories {
		directory, err := secureOpenDirectory(root, name, false, 0)
		if err != nil {
			return err
		}
		if err := directory.Chmod(0o700); err != nil {
			_ = directory.Close()
			return err
		}
		if err := directory.Close(); err != nil {
			return err
		}
	}
	return nil
}

func rejectSymlinks(root *os.Root) error {
	return fs.WalkDir(root.FS(), ".", func(_ string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return ErrArtifactIntegrity
		}
		return nil
	})
}

func syncRoot(root *os.Root) error {
	directory, err := root.Open(".")
	if err != nil {
		return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
	}
	defer directory.Close()
	if err := directory.Sync(); err != nil {
		return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
	}
	return nil
}
