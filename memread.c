// memread: print "pid footprint_bytes" for every process, then exit.
//
// Installed setuid root so Mem can see root-owned processes, which the kernel
// hides from unprivileged callers. Takes no arguments and reads no input; its only
// output is what `top` already shows every user.

#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <unistd.h>

int main(void) {
    int n = proc_listallpids(NULL, 0);
    if (n <= 0) return 1;
    n += 64;
    pid_t *pids = malloc(sizeof(pid_t) * n);
    if (!pids) return 1;
    n = proc_listallpids(pids, sizeof(pid_t) * n);
    // Privileges are only needed for the reads; drop them before writing output.
    struct rusage_info_v4 ri;
    static char out[1 << 17];
    size_t len = 0;
    for (int i = 0; i < n; i++) {
        if (pids[i] <= 0) continue;
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) continue;
        if (len + 48 > sizeof(out)) break;
        len += snprintf(out + len, sizeof(out) - len, "%d %llu\n", pids[i], ri.ri_phys_footprint);
    }
    if (setgid(getgid()) != 0 || setuid(getuid()) != 0) return 1;
    fwrite(out, 1, len, stdout);
    return 0;
}
