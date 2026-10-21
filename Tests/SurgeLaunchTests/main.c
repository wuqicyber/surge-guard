#include "LaunchFile.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    char directory[] = "/tmp/surge-launch-test.XXXXXX";
    assert(mkdtemp(directory));
    LaunchFile parent, executable, rejected;
    assert(launch_file_open(&parent, AT_FDCWD, directory, 1));
    int fd = openat(parent.fd, "Surge", O_CREAT | O_RDWR, 0700);
    assert(fd >= 0 && write(fd, "fixture", 7) == 7);
    close(fd);
    assert(launch_file_open(&executable, parent.fd, "Surge", 0));
    assert(executable.info.st_uid == getuid());
    assert(fcntl(executable.fd, F_GETFD) & FD_CLOEXEC);
    assert(launch_file_unchanged(&executable, parent.fd, "Surge"));
    assert(symlinkat("Surge", parent.fd, "link") == 0);
    assert(!launch_file_open(&rejected, parent.fd, "link", 0));
    assert(!launch_file_unchanged(&executable, parent.fd, "link"));
    assert(!launch_file_open(&rejected, parent.fd, "Surge", 1));
    assert(!launch_file_open(&rejected, AT_FDCWD, directory, 0));
    assert(renameat(parent.fd, "Surge", parent.fd, "old") == 0);
    fd = openat(parent.fd, "Surge", O_CREAT | O_RDWR, 0700);
    assert(fd >= 0 && write(fd, "fixture", 7) == 7);
    close(fd);
    assert(!launch_file_unchanged(&executable, parent.fd, "Surge"));
    close(executable.fd);
    assert(launch_file_open(&executable, parent.fd, "Surge", 0));
    fd = openat(parent.fd, "Surge", O_WRONLY | O_APPEND);
    assert(fd >= 0 && write(fd, "changed", 7) == 7);
    close(fd);
    assert(!launch_file_unchanged(&executable, parent.fd, "Surge"));
    close(executable.fd);
    assert(launch_file_open(&executable, parent.fd, "Surge", 0));
    assert(fchmod(executable.fd, 0755) == 0);
    assert(!launch_file_unchanged(&executable, parent.fd, "Surge"));
    close(executable.fd);
    assert(!launch_file_unchanged(&parent, AT_FDCWD, directory));
    assert(unlinkat(parent.fd, "Surge", 0) == 0);
    assert(unlinkat(parent.fd, "old", 0) == 0);
    assert(unlinkat(parent.fd, "link", 0) == 0);
    close(parent.fd);
    assert(rmdir(directory) == 0);
    puts("PASS: launcher inode/path/type/content/permission consistency; user ownership preserved");
    return 0;
}
