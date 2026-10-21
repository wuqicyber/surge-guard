#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <grp.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "LaunchFile.h"

int main(int argc, char **argv) {
    const char *bundle = "/Applications/Surge.app";
    const char *binary = "/Applications/Surge.app/Contents/MacOS/Surge";
    int check = argc == 2 && strcmp(argv[1], "--check") == 0;
    if (argc != 1 && !check) return 2;
    uid_t uid = getuid(), console = 0;
    gid_t gid = getegid();
    CFStringRef user = SCDynamicStoreCopyConsoleUser(NULL, &console, NULL);
    if (user) CFRelease(user);
    struct group *group = getgrnam("_surge_guard");
    if (uid < 501 || geteuid() != uid || console != uid || gid < 60000 || gid > 60999 ||
        !group || group->gr_gid != gid || group->gr_mem[0] != NULL) {
        fputs("Surge launcher requires the console user and its installed dedicated group\n", stderr);
        return 1;
    }
    const char *parts[] = {"/Applications", "Surge.app", "Contents", "MacOS", "Surge"};
    LaunchFile files[5];
    for (int i = 0; i < 5; i++) {
        if (!launch_file_open(&files[i], i == 0 ? AT_FDCWD : files[i - 1].fd, parts[i], i < 4)) {
            while (i > 0) close(files[--i].fd);
            fputs("Surge path is unsafe or changing; retry after the official update completes\n", stderr);
            return 1;
        }
    }
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)bundle, strlen(bundle), true);
    SecStaticCodeRef code = NULL;
    SecRequirementRef requirement = NULL;
    CFStringRef identity = CFSTR("anchor apple generic and identifier \"com.nssurge.surge-mac\" and certificate leaf[subject.OU] = \"YCKFLA6N72\"");
    OSStatus result = SecRequirementCreateWithString(identity, kSecCSDefaultFlags, &requirement);
    if (result == errSecSuccess) result = SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code);
    if (result == errSecSuccess) result = SecStaticCodeCheckValidity(code, kSecCSStrictValidate, requirement);
    if (code) CFRelease(code);
    if (requirement) CFRelease(requirement);
    if (url) CFRelease(url);
    if (result != errSecSuccess) {
        fputs("Official Surge signature validation failed\n", stderr);
        return 1;
    }
    struct passwd *account = getpwuid(uid);
    if (!account || setregid(gid, gid) != 0 || getgid() != gid || getegid() != gid) return 1;
    char *home = strdup(account->pw_dir), *name = strdup(account->pw_name);
    if (!home || !name) return 1;
    // A fixed environment prevents the set-group launcher from accepting injected code or proxy settings.
    char *environment[5] = {NULL, NULL, NULL, "PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL};
    if (asprintf(&environment[0], "HOME=%s", home) < 0 ||
        asprintf(&environment[1], "USER=%s", name) < 0 ||
        asprintf(&environment[2], "LOGNAME=%s", name) < 0 || chdir(home) != 0) return 1;
    umask(022);
    char *const args[] = {(char *)binary, NULL};
    // shortcut: pathname exec still has a final race; user-owned Sparkle updates require a mutable bundle.
    for (int i = 0; i < 5; i++) {
        if (!launch_file_unchanged(&files[i], i == 0 ? AT_FDCWD : files[i - 1].fd, parts[i])) {
            fputs("Surge changed during signature validation; launch refused\n", stderr);
            return 1;
        }
    }
    if (check) {
        for (int i = 0; i < 5; i++) close(files[i].fd);
        printf("{\"uid\":%u,\"gid\":%u}\n", uid, gid);
        return 0;
    }
    execve(binary, args, environment);
    perror("Surge launch");
    return 1;
}
