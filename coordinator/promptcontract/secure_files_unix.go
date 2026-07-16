//go:build darwin || linux

package promptcontract

import (
	"errors"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

func openVerifiedRoot(name string, mode fs.FileMode) (*os.Root, error) {
	directory, err := secureOpenAbsoluteDirectory(name, true, mode)
	if err != nil {
		return nil, err
	}
	defer directory.Close()

	root, err := os.OpenRoot(name)
	if err != nil {
		return nil, err
	}
	opened, err := root.Open(".")
	if err != nil {
		root.Close()
		return nil, err
	}
	defer opened.Close()
	directoryInfo, directoryErr := directory.Stat()
	openedInfo, openedErr := opened.Stat()
	pathInfo, pathErr := os.Lstat(name)
	if directoryErr != nil || openedErr != nil || pathErr != nil ||
		pathInfo.Mode()&os.ModeSymlink != 0 || !pathInfo.IsDir() ||
		!os.SameFile(directoryInfo, openedInfo) || !os.SameFile(openedInfo, pathInfo) {
		root.Close()
		return nil, ErrUnsafeArtifactPath
	}
	return root, nil
}

// renameRootEntry publishes one already-opened child atomically. Reopen and
// compare the root before renameat so path replacement cannot redirect the
// operation away from the os.Root used for all preceding writes.
func renameRootEntry(root *os.Root, rootPath, oldName, newName string) error {
	if !validRootEntryName(oldName) || !validRootEntryName(newName) {
		return ErrUnsafeArtifactPath
	}
	directory, err := secureOpenAbsoluteDirectory(rootPath, false, 0)
	if err != nil {
		return err
	}
	defer directory.Close()
	opened, err := root.Open(".")
	if err != nil {
		return err
	}
	defer opened.Close()
	directoryInfo, directoryErr := directory.Stat()
	openedInfo, openedErr := opened.Stat()
	if directoryErr != nil || openedErr != nil || !os.SameFile(directoryInfo, openedInfo) {
		return ErrUnsafeArtifactPath
	}
	return unix.Renameat(
		int(directory.Fd()), oldName,
		int(directory.Fd()), newName)
}

func validRootEntryName(name string) bool {
	return name != "" && name != "." && name != ".." &&
		!strings.ContainsAny(name, `/\`)
}

func secureOpenAbsoluteDirectory(name string, create bool, mode fs.FileMode) (*os.File, error) {
	cleaned := filepath.Clean(name)
	if !filepath.IsAbs(name) || cleaned != name {
		return nil, ErrUnsafeArtifactPath
	}
	fd, err := unix.Open("/", unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	current := os.NewFile(uintptr(fd), "/")
	if cleaned == "/" {
		return current, nil
	}
	for _, component := range strings.Split(strings.TrimPrefix(cleaned, "/"), "/") {
		nextFD, openErr := unix.Openat(
			int(current.Fd()),
			component,
			unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC,
			0,
		)
		if errors.Is(openErr, unix.ENOENT) && create {
			if mkdirErr := unix.Mkdirat(int(current.Fd()), component, uint32(mode.Perm())); mkdirErr != nil &&
				!errors.Is(mkdirErr, unix.EEXIST) {
				_ = current.Close()
				return nil, mkdirErr
			}
			nextFD, openErr = unix.Openat(
				int(current.Fd()),
				component,
				unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC,
				0,
			)
		}
		if openErr != nil {
			_ = current.Close()
			return nil, openErr
		}
		next := os.NewFile(uintptr(nextFD), component)
		_ = current.Close()
		current = next
	}
	return current, nil
}

func secureMkdirAll(root *os.Root, name string, mode fs.FileMode) error {
	directory, err := secureOpenDirectory(root, name, true, mode)
	if directory != nil {
		_ = directory.Close()
	}
	return err
}

func secureCreate(root *os.Root, name string, mode fs.FileMode) (*os.File, error) {
	parent, base, err := secureParent(root, name, true, 0o700)
	if err != nil {
		return nil, err
	}
	defer parent.Close()
	fd, err := unix.Openat(
		int(parent.Fd()),
		base,
		unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC,
		uint32(mode.Perm()),
	)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), name), nil
}

func secureOpenRegular(root *os.Root, name string) (*os.File, error) {
	parent, base, err := secureParent(root, name, false, 0)
	if err != nil {
		return nil, err
	}
	defer parent.Close()
	fd, err := unix.Openat(
		int(parent.Fd()),
		base,
		unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_CLOEXEC,
		0,
	)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), name)
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		_ = file.Close()
		if err != nil {
			return nil, err
		}
		return nil, ErrUnsafeArtifactPath
	}
	return file, nil
}

func secureOpenDirectory(
	root *os.Root,
	name string,
	create bool,
	mode fs.FileMode,
) (*os.File, error) {
	if name == "." {
		return root.Open(".")
	}
	if !validRelativePath(name) {
		return nil, ErrUnsafeArtifactPath
	}
	current, err := root.Open(".")
	if err != nil {
		return nil, err
	}
	for _, component := range strings.Split(name, "/") {
		fd, openErr := unix.Openat(
			int(current.Fd()),
			component,
			unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC,
			0,
		)
		if errors.Is(openErr, unix.ENOENT) && create {
			if mkdirErr := unix.Mkdirat(int(current.Fd()), component, uint32(mode.Perm())); mkdirErr != nil &&
				!errors.Is(mkdirErr, unix.EEXIST) {
				_ = current.Close()
				return nil, mkdirErr
			}
			fd, openErr = unix.Openat(
				int(current.Fd()),
				component,
				unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC,
				0,
			)
		}
		if openErr != nil {
			_ = current.Close()
			return nil, openErr
		}
		next := os.NewFile(uintptr(fd), component)
		_ = current.Close()
		current = next
	}
	return current, nil
}

func secureParent(
	root *os.Root,
	name string,
	create bool,
	mode fs.FileMode,
) (*os.File, string, error) {
	if !validRelativePath(name) {
		return nil, "", ErrUnsafeArtifactPath
	}
	parentName, base := path.Split(name)
	parentName = strings.TrimSuffix(parentName, "/")
	if parentName == "" {
		parentName = "."
	}
	parent, err := secureOpenDirectory(root, parentName, create, mode)
	if err != nil {
		return nil, "", err
	}
	return parent, base, nil
}
