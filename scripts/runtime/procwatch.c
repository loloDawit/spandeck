// Runtime verification helper (#3): records every fork, exec and exit of one process, using kqueue EVFILT_PROC.
// Needs no privileges for a process of the same user. Unlike sampling, it can't miss a short-lived child: the kernel
// reports each fork, and the child's path is looked up at once (it may already be gone, which is reported too).
//
//   procwatch PID     prints one line per event to stdout until PID exits
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define MAXKIDS 4096

static void stamp(char *buf, size_t n) {
    struct timeval tv; gettimeofday(&tv, NULL);
    struct tm tm; gmtime_r(&tv.tv_sec, &tm);
    size_t len = strftime(buf, n, "%Y-%m-%dT%H:%M:%S", &tm);
    snprintf(buf + len, n - len, ".%03dZ", (int)(tv.tv_usec / 1000));
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: procwatch PID\n"); return 64; }
    pid_t pid = (pid_t)atoi(argv[1]);
    int kq = kqueue();
    struct kevent ev;
    EV_SET(&ev, pid, EVFILT_PROC, EV_ADD | EV_ENABLE, NOTE_FORK | NOTE_EXEC | NOTE_EXIT, 0, NULL);
    if (kq < 0 || kevent(kq, &ev, 1, NULL, 0, NULL) < 0) { perror("procwatch: kevent"); return 2; }
    static pid_t seen[MAXKIDS]; int nseen = 0;
    char ts[64];
    stamp(ts, sizeof ts); printf("%s watching %d\n", ts, pid); fflush(stdout);
    for (;;) {
        struct kevent out;
        if (kevent(kq, NULL, 0, &out, 1, NULL) <= 0) continue;
        stamp(ts, sizeof ts);
        if (out.fflags & NOTE_FORK) {
            pid_t kids[MAXKIDS];
            int n = proc_listchildpids(pid, kids, sizeof kids);
            int reported = 0;
            for (int i = 0; i < n && i < MAXKIDS; i++) {
                int known = 0;
                for (int j = 0; j < nseen; j++) if (seen[j] == kids[i]) { known = 1; break; }
                if (known) continue;
                if (nseen < MAXKIDS) seen[nseen++] = kids[i];
                char path[PROC_PIDPATHINFO_MAXSIZE] = "?";
                proc_pidpath(kids[i], path, sizeof path);
                printf("%s fork child %d %s\n", ts, kids[i], path);
                reported = 1;
            }
            if (!reported) printf("%s fork child-already-exited\n", ts);
        }
        if (out.fflags & NOTE_EXEC) printf("%s exec (the watched process itself)\n", ts);
        fflush(stdout);
        if (out.fflags & NOTE_EXIT) { printf("%s exit\n", ts); fflush(stdout); return 0; }
    }
}
