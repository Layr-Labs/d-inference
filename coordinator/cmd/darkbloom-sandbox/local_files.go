package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/google/uuid"
	"golang.org/x/sys/unix"
)

func openLocalRegularFile(path string) (*os.File, os.FileInfo, error) {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, nil, errors.New("cannot open local file; select a readable regular file without a symlink")
	}
	file := os.NewFile(uintptr(fd), path)
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() < 0 {
		file.Close()
		return nil, nil, errors.New("upload source must be a regular file")
	}
	return file, info, nil
}

func unchangedLocalFile(file *os.File, before os.FileInfo) error {
	after, err := file.Stat()
	if err != nil || after.Size() != before.Size() || !after.ModTime().Equal(before.ModTime()) {
		return errors.New("local upload file changed; do not commit this transfer")
	}
	return nil
}

// Download publication stays relative to one open directory descriptor. The
// complete synced temporary inode is linked to an absent destination atomically;
// an existing file or symlink is never followed, replaced, or truncated.
type localDownload struct {
	directory                          int
	file                               *os.File
	temporary, destination, outputPath string
}

func newLocalDownload(path string) (*localDownload, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return nil, errors.New("invalid output path")
	}
	dirPath, name := filepath.Dir(abs), filepath.Base(abs)
	if name == "." || name == "/" || name == ".." {
		return nil, errors.New("output path must name a file")
	}
	directory, err := unix.Open(dirPath, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, errors.New("output parent must be an existing directory without a symlink")
	}
	var info unix.Stat_t
	if err := unix.Fstatat(directory, name, &info, unix.AT_SYMLINK_NOFOLLOW); err == nil || !errors.Is(err, unix.ENOENT) {
		unix.Close(directory)
		return nil, errors.New("output path already exists or cannot be inspected")
	}
	temporary := ".darkbloom-download-" + uuid.NewString()
	fd, err := unix.Openat(directory, temporary, unix.O_CREAT|unix.O_EXCL|unix.O_WRONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0o600)
	if err != nil {
		unix.Close(directory)
		return nil, errors.New("cannot create output staging file")
	}
	return &localDownload{directory: directory, file: os.NewFile(uintptr(fd), temporary), temporary: temporary, destination: name, outputPath: abs}, nil
}

func (d *localDownload) close() {
	_ = d.file.Close()
	_ = unix.Unlinkat(d.directory, d.temporary, 0)
	_ = unix.Close(d.directory)
}

func (d *localDownload) publish() error {
	if err := d.file.Sync(); err != nil {
		return errors.New("download sync failed before publication")
	}
	if err := unix.Linkat(d.directory, d.temporary, d.directory, d.destination, 0); err != nil {
		return errors.New("cannot publish download without overwriting an existing path")
	}
	if err := unix.Unlinkat(d.directory, d.temporary, 0); err != nil {
		return fmt.Errorf("download published at %s but staging cleanup failed", d.outputPath)
	}
	if err := unix.Fsync(d.directory); err != nil {
		return fmt.Errorf("download published at %s but directory sync is unconfirmed", d.outputPath)
	}
	return nil
}
