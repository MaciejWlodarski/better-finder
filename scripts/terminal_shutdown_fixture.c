/* Private native QA fixture. No process creation or external execution. */
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/time.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <libproc.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include <time.h>
#include <limits.h>

static double end_time;
static int fd = -1;
static void hard_kill(int sig) { (void)sig; kill(getpid(), SIGKILL); _exit(125); }
static double now(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) hard_kill(0);
    return (double)t.tv_sec + (double)t.tv_nsec / 1000000000.0;
}
static void arm(double seconds) {
    double remaining = end_time - now();
    if (seconds > remaining) seconds = remaining;
    if (seconds <= 0 || seconds < .000001) hard_kill(0);
    /* Round DOWN; a sub-microsecond remainder kills rather than disabling. */
    unsigned long long micros = (unsigned long long)(seconds * 1000000.0);
    if (!micros) hard_kill(0);
    struct itimerval timer = {0};
    timer.it_value.tv_sec = (time_t)(micros / 1000000ULL);
    timer.it_value.tv_usec = (suseconds_t)(micros % 1000000ULL);
    if (setitimer(ITIMER_REAL, &timer, NULL)) hard_kill(0);
}
static void cleanup(void) {
    double remaining = end_time - now();
    if (remaining <= 0) hard_kill(0);
    arm(remaining < .5 ? remaining : .5);
    if (kill(getpid(), SIGTERM)) hard_kill(0);
    for (;;) pause(); /* Only resistant mode reaches here; alarm stays unblocked. */
}
static int atom(const char *s, size_t min, size_t max) {
    size_t n = strlen(s);
    if (n < min || n > max) return 0;
    for (size_t i = 0; i < n; i++)
        if (!((s[i] >= 'a' && s[i] <= 'z') || (s[i] >= '0' && s[i] <= '9') || s[i] == '-')) return 0;
    return 1;
}
static void send_frame(const char *s) {
    size_t n = strlen(s);
    if (n > 256 || send(fd, s, n, 0) != (ssize_t)n) cleanup();
}
static int inspect(const char *text) {
    char *tail = NULL;
    long id = strtol(text, &tail, 10);
    if (!tail || *tail || id <= 1 || id > INT_MAX) return 64;
    struct proc_bsdinfo b;
    int n = proc_pidinfo((pid_t)id, PROC_PIDTBSDINFO, 0, &b, sizeof b);
    if (n != (int)sizeof b) {
        /* Targeted kernel query distinguishes absent from inaccessible. */
        int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, (int)id};
        struct kinfo_proc info; size_t bytes = sizeof info;
        if (sysctl(mib, 4, &info, &bytes, NULL, 0) == 0 && bytes == 0) puts("ABSENT");
        else puts("UNKNOWN");
        return 0;
    }
    if (b.pbi_status == SZOMB) {
        printf("ZOMBIE %u %llu %llu\n", b.pbi_pid,
               (unsigned long long)b.pbi_start_tvsec, (unsigned long long)b.pbi_start_tvusec);
        return 0;
    }
    char path[PROC_PIDPATHINFO_MAXSIZE];
    int size = proc_pidpath((pid_t)id, path, sizeof path);
    if (size <= 0) {
        /* A zombie is independently identified by BSD info, even without a path. */
        if (b.pbi_status == SZOMB) {
            printf("ZOMBIE %u %llu %llu\n", b.pbi_pid,
                   (unsigned long long)b.pbi_start_tvsec, (unsigned long long)b.pbi_start_tvusec);
            return 0;
        }
        puts("UNKNOWN"); return 0;
    }
    printf("LIVE %u %u %u %u %u %llu %llu\n%s\n", b.pbi_pid, b.pbi_ppid,
           b.pbi_pgid, b.pbi_uid, b.pbi_status,
           (unsigned long long)b.pbi_start_tvsec, (unsigned long long)b.pbi_start_tvusec, path);
    return 0;
}
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--constants")) {
        printf("BFSC1 %d %d %zu %zu %d %d\n", SOL_LOCAL, LOCAL_PEERPID, sizeof(pid_t), sizeof(uid_t), SOL_SOCKET, SO_NOSIGPIPE);
        return 0;
    }
    if (argc == 3 && !strcmp(argv[1], "--identity")) return inspect(argv[2]);
    if (argc != 6) return 64;
    const char *path = argv[1], *nonce = argv[2], *case_id = argv[3], *mode = argv[4];
    if (strcmp(argv[5], "fixture-v1") || !atom(nonce, 32, 32) || !atom(case_id, 1, 32) ||
        (strcmp(mode, "default") && strcmp(mode, "resistant"))) return 64;
    struct sigaction alarm_action = {0}, term_action = {0};
    alarm_action.sa_handler = hard_kill;
    term_action.sa_handler = !strcmp(mode, "default") ? SIG_DFL : SIG_IGN;
    sigemptyset(&alarm_action.sa_mask); sigemptyset(&term_action.sa_mask);
    sigset_t unblocked; sigemptyset(&unblocked); sigaddset(&unblocked, SIGALRM); sigaddset(&unblocked, SIGTERM);
    if (sigaction(SIGALRM, &alarm_action, NULL) || sigaction(SIGTERM, &term_action, NULL) ||
        sigprocmask(SIG_UNBLOCK, &unblocked, NULL)) return 65;
    end_time = now() + 12.0; arm(12.0);
    struct sockaddr_un address = {0};
    if (path[0] != '/' || strlen(path) >= sizeof address.sun_path) return 64;
    address.sun_family = AF_UNIX; address.sun_len = sizeof address;
    memcpy(address.sun_path, path, strlen(path) + 1);
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    int one = 1;
    if (fd < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) || fcntl(fd, F_SETFL, O_NONBLOCK) ||
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one)) cleanup();
    if (connect(fd, (struct sockaddr *)&address, sizeof address) && errno != EINPROGRESS) cleanup();
    struct pollfd event = {fd, POLLOUT, 0};
    if (poll(&event, 1, 1000) != 1) cleanup();
    int error = 0; socklen_t length = sizeof error;
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) || error) cleanup();
    close(STDOUT_FILENO); close(STDERR_FILENO);
    char line[257];
    int n = snprintf(line, sizeof line, "READY %s %s %d %d %d\n", nonce, case_id, getpid(), getpgrp(), getppid());
    if (n <= 0 || n >= (int)sizeof line) cleanup();
    send_frame(line);
    size_t used = 0; int challenged = 0;
    for (;;) {
        if (now() >= end_time) hard_kill(0);
        struct pollfd input = {fd, POLLIN | POLLHUP, 0};
        int ready = poll(&input, 1, 50);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0) cleanup();
        if (!ready) continue;
        char c;
        ssize_t count = recv(fd, &c, 1, 0);
        if (!count) cleanup();
        if (count < 0) { if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue; cleanup(); }
        if (used >= 256 || c == '\0' || c == '\r') cleanup();
        line[used++] = c;
        if (c != '\n') continue;
        line[used - 1] = 0;
        char expected[257];
        snprintf(expected, sizeof expected, "CLEANUP %s %s", nonce, case_id);
        if (!strcmp(line, expected)) cleanup();
        snprintf(expected, sizeof expected, "CHALLENGE %s %s ", nonce, case_id);
        size_t prefix = strlen(expected);
        if (challenged || strncmp(line, expected, prefix) || !atom(line + prefix, 32, 32)) cleanup();
        char challenge[33]; memcpy(challenge, line + prefix, 33); challenged = 1;
        snprintf(line, sizeof line, "RESPONSE %s %s %s\n", nonce, case_id, challenge);
        send_frame(line); used = 0;
    }
}
