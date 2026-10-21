#ifndef SURGE_LAUNCH_FILE_H
#define SURGE_LAUNCH_FILE_H
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct { int fd; struct stat info; } LaunchFile;

static int launch_same_stat(const struct stat *a, const struct stat *b) {
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino && a->st_mode == b->st_mode &&
        a->st_uid == b->st_uid && a->st_gid == b->st_gid && a->st_size == b->st_size &&
        a->st_mtimespec.tv_sec == b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec &&
        a->st_ctimespec.tv_sec == b->st_ctimespec.tv_sec && a->st_ctimespec.tv_nsec == b->st_ctimespec.tv_nsec;
}

static int launch_file_unchanged(const LaunchFile *file, int parent, const char *name) {
    struct stat opened, named;
    return fstat(file->fd, &opened) == 0 && fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 &&
        launch_same_stat(&file->info, &opened) && launch_same_stat(&opened, &named);
}

static int launch_file_open(LaunchFile *file, int parent, const char *name, int directory) {
    file->fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0));
    if (file->fd < 0) return 0;
    if (fstat(file->fd, &file->info) == 0 &&
        (directory ? S_ISDIR(file->info.st_mode) : S_ISREG(file->info.st_mode)) &&
        launch_file_unchanged(file, parent, name)) return 1;
    close(file->fd); file->fd = -1;
    return 0;
}
#endif
