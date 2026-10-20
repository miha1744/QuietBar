#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/proc_info.h>
#include <unistd.h>

/* Read-only identity query for one explicit PID, used before exact cleanup. */
int main(int argc, char **argv) {
    if (argc != 2) return 64;
    char *end = NULL;
    long value = strtol(argv[1], &end, 10);
    if (!end || *end || value <= 1 || value > 2147483647) return 64;
    struct proc_bsdinfo info = {0};
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidinfo((pid_t)value, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)
        || proc_pidpath((pid_t)value, path, sizeof(path)) <= 0) return 1;
    printf("{\"pid\":%ld,\"uid\":%u,\"parentPID\":%u,\"startSeconds\":%llu,\"startMicroseconds\":%llu,\"executablePath\":\"",
           value, info.pbi_uid, info.pbi_ppid, info.pbi_start_tvsec, info.pbi_start_tvusec);
    for (const char *s = path; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') printf("\\%c", c);
        else if (c < 32) printf("\\u%04x", c);
        else putchar(c);
    }
    puts("\"}");
    return 0;
}
