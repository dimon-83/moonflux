#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

/*
 * Mode mapping (host-agnostic, translated here):
 *   0 = read-only                     -> O_RDONLY
 *   1 = create-or-truncate, write     -> O_WRONLY | O_CREAT | O_TRUNC
 *   2 = create-or-append, write       -> O_WRONLY | O_CREAT | O_APPEND
 *   3 = create-or-open, read/write    -> O_RDWR   | O_CREAT
 * Every open creates missing parent-independent path components with
 * mode 0644; use mf_fs_mkdirs for directories.
 */
int mf_fs_open(const uint8_t *buf, int len, int mode) {
  char path[4096];
  if (len < 0 || len >= 4096) return -EINVAL;
  memcpy(path, buf, len);
  path[len] = 0;
  int flags;
  switch (mode) {
    case 0: flags = O_RDONLY; break;
    case 1: flags = O_WRONLY | O_CREAT | O_TRUNC; break;
    case 2: flags = O_WRONLY | O_CREAT | O_APPEND; break;
    case 3: flags = O_RDWR | O_CREAT; break;
    case 4: flags = O_RDWR | O_CREAT | O_APPEND; break;
    default: return -EINVAL;
  }
  return open(path, flags, 0644);
}

ssize_t mf_fs_pread(int fd, uint8_t *buf, int len, int offset) {
  return pread(fd, buf, len, (off_t)offset);
}

int mf_fs_write(int fd, const uint8_t *buf, int len) {
  return (int)write(fd, buf, len);
}

int mf_fs_close(int fd) { return close(fd); }

/* Sequential read from a descriptor (fd 0 = stdin for P1's stdin
 * source). Returns bytes read, 0 at EOF, negative -errno. */
int mf_fs_read(int fd, uint8_t *buf, int len) {
  return (int)read(fd, buf, len);
}

int mf_fs_filesize(int fd) {
  struct stat st;
  if (fstat(fd, &st) != 0) return -errno;
  return (int)st.st_size;
}

int mf_fs_flush(int fd) { return fsync(fd); }

/* mkdir -p semantics: create every path prefix, ignoring EEXIST. */
int mf_fs_mkdirs(const uint8_t *buf, int len) {
  char path[4096];
  if (len < 0 || len >= 4096) return -EINVAL;
  memcpy(path, buf, len);
  path[len] = 0;
  for (int i = 1; i < len; i++) {
    if (path[i] == '/') {
      path[i] = 0;
      if (mkdir(path, 0755) != 0 && errno != EEXIST) return -errno;
      path[i] = '/';
    }
  }
  if (mkdir(path, 0755) != 0 && errno != EEXIST) return -errno;
  return 0;
}

int mf_fs_remove(const uint8_t *buf, int len) {
  char path[4096];
  if (len < 0 || len >= 4096) return -EINVAL;
  memcpy(path, buf, len);
  path[len] = 0;
  return unlink(path);
}

/* Nanosecond mtime for change detection: second granularity aliases
 * rapid apply+reload cycles. Returns ns since epoch, or -errno. */
int64_t mf_fs_mtime(const uint8_t *buf, int len) {
  char path[4096];
  if (len < 0 || len >= 4096) return -EINVAL;
  memcpy(path, buf, len);
  path[len] = 0;
  struct stat st;
  if (stat(path, &st) != 0) return -errno;
  return (int64_t)st.st_mtimespec.tv_sec * 1000000000LL +
         (int64_t)st.st_mtimespec.tv_nsec;
}

int mf_fs_truncate(int fd, int new_size) {
  if (ftruncate(fd, (off_t)new_size) != 0) return -errno;
  return 0;
}

int mf_fs_exists(const uint8_t *buf, int len) {
  char path[4096];
  if (len < 0 || len >= 4096) return -EINVAL;
  memcpy(path, buf, len);
  path[len] = 0;
  struct stat st;
  if (stat(path, &st) != 0) {
    if (errno == ENOENT) return 0;
    return -errno;
  }
  return 1;
}
