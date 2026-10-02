// mem: terminal memory monitor for macOS. The same numbers as Mem.app.
//
// No polling. The screen redraws on keys and terminal resizes. The data is re-read
// on `r`, when the kernel reports a memory-pressure change, and after quitting a
// process. Root-owned processes come from the setuid memread helper when installed,
// else from one /usr/bin/top snapshot.
//
//   mem            interactive
//   mem -1 [-n N]  print one snapshot (also when stdout isn't a terminal); -a for all

#include <ctype.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach/mach.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

#define HELPER "/usr/local/libexec/memread"
#define MAXPROC 8192

typedef struct {
    uint64_t physical, app, wired, compressed, cached, free, swap_used, swap_total;
    int pressure, free_pct;
} sysmem_t;

typedef struct {
    pid_t pid;
    uint64_t fp;
    char name[48];
    char mine, priv;
} proc_t;

typedef struct { pid_t pid; uint64_t fp; } pf_t;

static sysmem_t sm;
static proc_t procs[MAXPROC];
static int nprocs;
static int view[MAXPROC];
static int nview;
static pf_t extra[MAXPROC];
static int nextra;

static int helper_ok;
static uid_t me;
static int color = 1;

// Interactive state.
static int rows = 24, cols = 80;
static int sort_key;            // 0 memory, 1 name, 2 pid
static pid_t sel_pid = -1;
static int top_row;
static char filter[48];
static int filtering;
static int confirm;             // 0 none, 1 quit, 2 force quit
static char status[200];
static char updated[16];
static struct termios orig_tio;
static int raw_on;

// ---------------------------------------------------------------------------
// Reading

static uint64_t sub(uint64_t a, uint64_t b) { return a > b ? a - b : 0; }

static void read_sysmem(void) {
    size_t sz = sizeof sm.physical;
    sysctlbyname("hw.memsize", &sm.physical, &sz, NULL, 0);
    struct xsw_usage sw;
    sz = sizeof sw;
    if (sysctlbyname("vm.swapusage", &sw, &sz, NULL, 0) == 0) { sm.swap_used = sw.xsu_used; sm.swap_total = sw.xsu_total; }
    int v;
    sz = sizeof v;
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &v, &sz, NULL, 0) == 0) sm.pressure = v;
    sz = sizeof v;
    if (sysctlbyname("kern.memorystatus_level", &v, &sz, NULL, 0) == 0) sm.free_pct = v;

    static mach_port_t host;
    if (!host) host = mach_host_self();
    vm_statistics64_data_t s;
    mach_msg_type_number_t c = HOST_VM_INFO64_COUNT;
    if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&s, &c) != KERN_SUCCESS) return;
    uint64_t pg = vm_kernel_page_size;
    // Activity Monitor's breakdown.
    sm.app = sub(s.internal_page_count, s.purgeable_count) * pg;
    sm.wired = (uint64_t)s.wire_count * pg;
    sm.compressed = (uint64_t)s.compressor_page_count * pg;
    sm.cached = ((uint64_t)s.external_page_count + s.purgeable_count) * pg;
    sm.free = (uint64_t)s.free_count * pg;
}

// Innermost .app bundle in the executable path ("Firefox GPU Helper"), else the binary.
static void proc_label(pid_t pid, char *out, size_t n) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    out[0] = 0;
    if (proc_pidpath(pid, path, sizeof path) > 0) {
        const char *best = NULL, *last = path;
        size_t blen = 0;
        for (const char *seg = path; seg && *seg;) {
            const char *slash = strchr(seg, '/');
            size_t len = slash ? (size_t)(slash - seg) : strlen(seg);
            if (len > 4 && strncmp(seg + len - 4, ".app", 4) == 0) { best = seg; blen = len - 4; }
            if (len) last = seg;
            seg = slash ? slash + 1 : NULL;
        }
        if (best) snprintf(out, n, "%.*s", (int)blen, best);
        else snprintf(out, n, "%s", last);
    }
    if (!out[0]) proc_name(pid, out, (uint32_t)n);
    if (!out[0]) snprintf(out, n, "pid %d", pid);
}

static int cmp_pf(const void *a, const void *b) {
    pid_t x = ((const pf_t *)a)->pid, y = ((const pf_t *)b)->pid;
    return (x > y) - (x < y);
}

// Footprints for every process from memread (setuid root) or, failing that, top.
static int read_privileged(void) {
    int fd[2];
    if (pipe(fd) != 0) return -1;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fd[1], 1);
    posix_spawn_file_actions_addclose(&fa, fd[0]);
    posix_spawn_file_actions_addclose(&fa, fd[1]);
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
    char *argv_helper[] = { HELPER, NULL };
    char *argv_top[] = { "/usr/bin/top", "-l", "1", "-s", "0", "-stats", "pid,mem", NULL };
    pid_t child;
    int rc = posix_spawn(&child, helper_ok ? HELPER : "/usr/bin/top", &fa, NULL, helper_ok ? argv_helper : argv_top, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(fd[1]);
    if (rc != 0) { close(fd[0]); return -1; }
    FILE *f = fdopen(fd[0], "r");
    char line[256];
    nextra = 0;
    while (f && fgets(line, sizeof line, f) && nextra < MAXPROC) {
        long pid;
        if (helper_ok) {
            unsigned long long fp;
            if (sscanf(line, "%ld %llu", &pid, &fp) == 2) extra[nextra++] = (pf_t){ (pid_t)pid, fp };
            continue;
        }
        char sz[32];   // top: "393    384M+"
        if (sscanf(line, "%ld %31s", &pid, sz) != 2) continue;
        size_t len = strlen(sz);
        while (len && (sz[len - 1] == '+' || sz[len - 1] == '-')) sz[--len] = 0;
        if (len < 2 || !isdigit((unsigned char)sz[0])) continue;
        char unit = sz[len - 1];
        double mult = unit == 'K' ? 1024.0 : unit == 'M' ? 1048576.0 : unit == 'G' ? 1073741824.0 : unit == 'B' ? 1.0 : 0;
        if (mult > 0) extra[nextra++] = (pf_t){ (pid_t)pid, (uint64_t)(atof(sz) * mult) };
    }
    if (f) fclose(f);
    waitpid(child, NULL, 0);
    qsort(extra, nextra, sizeof(pf_t), cmp_pf);
    return 0;
}

static void read_procs(void) {
    static pid_t pids[MAXPROC];
    int n = proc_listallpids(pids, sizeof pids);
    if (n < 0) n = 0;
    if (n > MAXPROC) n = MAXPROC;
    nprocs = 0;
    int missing = 0;
    for (int i = 0; i < n; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;
        proc_t *p = &procs[nprocs];
        p->pid = pid;
        struct rusage_info_v4 ri;
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) == 0) { p->fp = ri.ri_phys_footprint; p->priv = 0; }
        else { p->fp = 0; p->priv = 1; missing++; }
        struct proc_bsdshortinfo bi;
        p->mine = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bi, sizeof bi) > 0 && bi.pbsi_uid == me;
        proc_label(pid, p->name, sizeof p->name);
        nprocs++;
    }
    int have_extra = missing && read_privileged() == 0;
    int k = 0;
    for (int i = 0; i < nprocs; i++) {
        if (procs[i].priv) {
            pf_t key = { procs[i].pid, 0 };
            pf_t *hit = have_extra ? bsearch(&key, extra, nextra, sizeof(pf_t), cmp_pf) : NULL;
            if (!hit) continue;   // exited, or unreadable: drop rather than show a wrong 0
            procs[i].fp = hit->fp;
        }
        procs[k++] = procs[i];
    }
    nprocs = k;
    time_t t = time(NULL);
    strftime(updated, sizeof updated, "%H:%M:%S", localtime(&t));
}

// ---------------------------------------------------------------------------
// View: filter + sort

static int ci_contains(const char *hay, const char *needle) {
    size_t n = strlen(needle);
    if (!n) return 1;
    for (; *hay; hay++)
        if (strncasecmp(hay, needle, n) == 0) return 1;
    return 0;
}

static int cmp_view(const void *a, const void *b) {
    const proc_t *x = &procs[*(const int *)a], *y = &procs[*(const int *)b];
    switch (sort_key) {
    case 1: return strcasecmp(x->name, y->name);
    case 2: return (x->pid > y->pid) - (x->pid < y->pid);
    default: return (y->fp > x->fp) - (y->fp < x->fp);
    }
}

static void build_view(void) {
    nview = 0;
    char *end;
    long pidq = strtol(filter, &end, 10);
    int by_pid = filter[0] && !*end;
    for (int i = 0; i < nprocs; i++)
        if (by_pid ? procs[i].pid == pidq : ci_contains(procs[i].name, filter)) view[nview++] = i;
    qsort(view, nview, sizeof(int), cmp_view);
}

static int sel_index(void) {
    for (int i = 0; i < nview; i++)
        if (procs[view[i]].pid == sel_pid) return i;
    return -1;
}

// ---------------------------------------------------------------------------
// Output

static char out[1 << 16];
static size_t olen;

static void put(const char *fmt, ...) {
    if (olen >= sizeof out) return;
    va_list ap;
    va_start(ap, fmt);
    int w = vsnprintf(out + olen, sizeof out - olen, fmt, ap);
    va_end(ap);
    if (w > 0) olen += (size_t)w < sizeof out - olen ? (size_t)w : sizeof out - olen - 1;
}

static void sgr(const char *code) { if (color) put("\x1b[%sm", code); }

static const char *fmt_bytes(uint64_t b, char *buf) {
    double gb = b / 1073741824.0;
    if (gb >= 1) snprintf(buf, 16, "%.2f GB", gb);
    else snprintf(buf, 16, "%.0f MB", b / 1048576.0);
    return buf;
}

// Write at most `width` columns of a UTF-8 string, padding to `width` when pad is set.
static void put_cols(const char *s, int width, int pad) {
    int used = 0;
    const char *p = s;
    while (*p && used < width) {
        const char *start = p++;
        while ((*p & 0xC0) == 0x80) p++;
        if (olen + (size_t)(p - start) < sizeof out) { memcpy(out + olen, start, (size_t)(p - start)); olen += (size_t)(p - start); }
        used++;
    }
    if (pad) while (used++ < width) put(" ");
}

static const char *pressure_word(int *code) {
    if (sm.pressure >= 4) { *code = 31; return "Critical"; }
    if (sm.pressure >= 2) { *code = 33; return "Warning"; }
    *code = 32;
    return "Normal";
}

static void put_totals_line(void) {
    char a[16], b[16], c[16], d[16], e[16], f[16];
    struct { const char *label, *code; uint64_t v; } seg[] = {
        { "app", "34", sm.app }, { "wired", "33", sm.wired }, { "compressed", "35", sm.compressed }, { "cached", "90", sm.cached },
    };
    char *bufs[] = { a, b, c, d };
    for (int i = 0; i < 4; i++) {
        if (color) { sgr(seg[i].code); put("● "); sgr("0"); }
        put("%s %s  ", seg[i].label, fmt_bytes(seg[i].v, bufs[i]));
    }
    put("free %s  swap %s", fmt_bytes(sm.free, e), fmt_bytes(sm.swap_used, f));
}

static void render(void) {
    struct winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_row && ws.ws_col) { rows = ws.ws_row; cols = ws.ws_col; }
    olen = 0;
    put("\x1b[?25l\x1b[H");

    char u[16], t[16];
    int pc;
    const char *pw = pressure_word(&pc);
    // Line 1: used + pressure
    sgr("1"); put(" mem"); sgr("0");
    put("  used %s of %s   pressure ", fmt_bytes(sm.app + sm.wired + sm.compressed, u), fmt_bytes(sm.physical, t));
    sgr(pc == 32 ? "32" : pc == 33 ? "33" : "31"); put("%s", pw); sgr("0");
    put(" · %d%% free   %d procs · %s\x1b[K\r\n", sm.free_pct, nprocs, updated);
    // Line 2: breakdown
    put(" "); put_totals_line(); put("\x1b[K\r\n");
    // Line 3: bar across physical memory
    int bw = cols - 2;
    put(" ");
    if (sm.physical && bw > 0) {
        uint64_t parts[] = { sm.wired, sm.app, sm.compressed, sm.cached };
        const char *codes[] = { "33", "34", "35", "90" };
        int drawn = 0;
        for (int i = 0; i < 4; i++) {
            int w = (int)((double)parts[i] / sm.physical * bw + 0.5);
            if (drawn + w > bw) w = bw - drawn;
            sgr(codes[i]);
            for (int j = 0; j < w; j++) put("█");
            drawn += w;
        }
        sgr("2");
        for (; drawn < bw; drawn++) put("░");
        sgr("0");
    }
    put("\x1b[K\r\n");
    // Line 4: column header
    const char *mark[3] = { "", "", "" };
    mark[sort_key] = sort_key == 0 ? "▼" : "▲";
    sgr("7");
    char hdr[64];
    snprintf(hdr, sizeof hdr, " %7s%s %10s%s  PROCESS%s", "PID", mark[2][0] ? mark[2] : " ", "MEMORY", mark[0][0] ? mark[0] : " ", mark[1]);
    put_cols(hdr, cols, 1);
    sgr("0");
    put("\r\n");

    // Rows
    int list_h = rows - 5;
    if (list_h < 1) list_h = 1;
    int si = sel_index();
    if (si < 0 && nview) { si = 0; sel_pid = procs[view[0]].pid; }
    if (si >= 0) {
        if (si < top_row) top_row = si;
        if (si >= top_row + list_h) top_row = si - list_h + 1;
    }
    if (top_row > nview - list_h) top_row = nview - list_h;
    if (top_row < 0) top_row = 0;
    for (int r = 0; r < list_h; r++) {
        int i = top_row + r;
        if (i < nview) {
            proc_t *p = &procs[view[i]];
            char m[16], line[96];
            snprintf(line, sizeof line, " %7d  %10s   ", p->pid, fmt_bytes(p->fp, m));
            if (i == si) sgr("7");
            put_cols(line, cols, 0);
            int rest = cols - 22;
            if (rest > 0) put_cols(p->name, rest, i == si);
            if (i == si) sgr("0");
        }
        put("\x1b[K\r\n");
    }

    // Footer: prompt, status, or key help
    if (confirm) {
        int si2 = sel_index();
        proc_t *p = si2 >= 0 ? &procs[view[si2]] : NULL;
        sgr("1;33");
        char q[128];
        snprintf(q, sizeof q, " %s %s (PID %d)? y/n", confirm == 2 ? "Force quit" : "Quit", p ? p->name : "?", p ? p->pid : 0);
        put_cols(q, cols, 0);
        sgr("0");
    } else if (filtering) {
        put(" filter: %s", filter);
        put("\x1b[K\x1b[?25h");
        if (write(STDOUT_FILENO, out, olen) < 0) {}
        return;
    } else if (status[0]) {
        put_cols(status, cols, 0);
    } else {
        sgr("2");
        put_cols(" q quit  r refresh  ↑↓/jk move  s sort  / filter  x quit process  X force quit", cols, 0);
        sgr("0");
    }
    put("\x1b[K");
    if (write(STDOUT_FILENO, out, olen) < 0) {}
}

// ---------------------------------------------------------------------------
// Terminal

static void raw_mode(int on) {
    if (on && !raw_on) {
        tcgetattr(STDIN_FILENO, &orig_tio);
        struct termios t = orig_tio;
        t.c_lflag &= ~(ICANON | ECHO);
        t.c_cc[VMIN] = 1;
        t.c_cc[VTIME] = 0;
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &t);
        if (write(STDOUT_FILENO, "\x1b[?1049h\x1b[?25l", 14) < 0) {}
        raw_on = 1;
    } else if (!on && raw_on) {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig_tio);
        if (write(STDOUT_FILENO, "\x1b[?25h\x1b[?1049l", 14) < 0) {}
        raw_on = 0;
    }
}

static void restore(void) { raw_mode(0); }

static void refresh_data(void) {
    read_sysmem();
    read_procs();
    build_view();
}

static void move_sel(int delta) {
    if (!nview) return;
    int i = sel_index();
    if (i < 0) i = 0;
    i += delta;
    if (i < 0) i = 0;
    if (i >= nview) i = nview - 1;
    sel_pid = procs[view[i]].pid;
}

static void do_kill(int force) {
    int i = sel_index();
    if (i < 0) return;
    proc_t *p = &procs[view[i]];
    if (kill(p->pid, force ? SIGKILL : SIGTERM) == 0) {
        snprintf(status, sizeof status, " sent %s to %s (PID %d)", force ? "SIGKILL" : "SIGTERM", p->name, p->pid);
    } else {
        snprintf(status, sizeof status, " couldn't quit %s: %s", p->name,
                 errno == EPERM ? "it belongs to the system or another user (needs admin)" : strerror(errno));
    }
    // Re-read shortly after, once the process has had a chance to exit.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        refresh_data();
        render();
    });
}

static void on_input(void) {
    unsigned char buf[64];
    ssize_t n = read(STDIN_FILENO, buf, sizeof buf);
    if (n <= 0) { restore(); exit(0); }
    int list_h = rows - 5 > 1 ? rows - 5 : 1;
    for (ssize_t i = 0; i < n; i++) {
        unsigned char c = buf[i];
        if (filtering) {
            size_t len = strlen(filter);
            if (c == '\r' || c == '\n') filtering = 0;
            else if (c == 27) { filtering = 0; filter[0] = 0; i = n; }
            else if (c == 127 || c == 8) { if (len) filter[len - 1] = 0; }
            else if (c >= 32 && len + 1 < sizeof filter) { filter[len] = (char)c; filter[len + 1] = 0; }
            build_view();
            continue;
        }
        if (confirm) {
            if (c == 'y' || c == 'Y') do_kill(confirm == 2);
            confirm = 0;
            continue;
        }
        status[0] = 0;
        if (c == 27 && i + 2 < n && buf[i + 1] == '[') {
            unsigned char k = buf[i + 2];
            i += 2;
            if (k == 'A') move_sel(-1);
            else if (k == 'B') move_sel(1);
            else if ((k == '5' || k == '6') && i + 1 < n && buf[i + 1] == '~') { i++; move_sel(k == '5' ? -list_h : list_h); }
            else if (k == 'H') move_sel(-nview);
            else if (k == 'F') move_sel(nview);
            continue;
        }
        switch (c) {
        case 'q': restore(); exit(0);
        case 'r': refresh_data(); break;
        case 'k': move_sel(-1); break;
        case 'j': move_sel(1); break;
        case 'g': move_sel(-nview); break;
        case 'G': move_sel(nview); break;
        case ' ': move_sel(list_h); break;
        case 's': sort_key = (sort_key + 1) % 3; build_view(); break;
        case '/': filtering = 1; break;
        case 27: if (filter[0]) { filter[0] = 0; build_view(); } break;
        case 'x': if (sel_index() >= 0) confirm = 1; break;
        case 'X': if (sel_index() >= 0) confirm = 2; break;
        }
    }
    render();
}

// ---------------------------------------------------------------------------
// One-shot output

static void snapshot(int limit) {
    refresh_data();
    char u[16], t[16], m[16];
    int pc;
    const char *pw = pressure_word(&pc);
    put("used %s of %s  pressure ", fmt_bytes(sm.app + sm.wired + sm.compressed, u), fmt_bytes(sm.physical, t));
    sgr(pc == 32 ? "32" : pc == 33 ? "33" : "31"); put("%s", pw); sgr("0");
    put(" · %d%% free\n", sm.free_pct);
    put_totals_line();
    put("\n%7s %10s  PROCESS\n", "PID", "MEMORY");
    for (int i = 0; i < nview && (limit <= 0 || i < limit); i++) {
        proc_t *p = &procs[view[i]];
        put("%7d %10s  %s\n", p->pid, fmt_bytes(p->fp, m), p->name);
        if (olen > sizeof out - 256) { fwrite(out, 1, olen, stdout); olen = 0; }
    }
    fwrite(out, 1, olen, stdout);
}

int main(int argc, char **argv) {
    me = getuid();
    struct stat st;
    helper_ok = stat(HELPER, &st) == 0 && st.st_uid == 0 && (st.st_mode & S_ISUID);

    int once = !isatty(STDOUT_FILENO) || !isatty(STDIN_FILENO), limit = 25;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-1") || !strcmp(argv[i], "--once")) once = 1;
        else if (!strcmp(argv[i], "-a")) limit = 0;
        else if (!strcmp(argv[i], "-n") && i + 1 < argc) limit = atoi(argv[++i]);
        else {
            fprintf(stderr, "usage: mem [-1] [-n N | -a]\n"
                            "  interactive by default; -1 prints one snapshot (top 25, -n N, -a for all)\n");
            return argv[i][1] == 'h' ? 0 : 2;
        }
    }
    if (once) {
        color = isatty(STDOUT_FILENO);
        snapshot(limit);
        return 0;
    }

    raw_mode(1);
    atexit(restore);
    refresh_data();
    render();

    dispatch_queue_t q = dispatch_get_main_queue();
    dispatch_source_t in = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, q);
    dispatch_source_set_event_handler(in, ^{ on_input(); });
    dispatch_resume(in);

    // Kernel push: memory pressure changed level.
    dispatch_source_t mp = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
        DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL, q);
    dispatch_source_set_event_handler(mp, ^{ refresh_data(); render(); });
    dispatch_resume(mp);

    int sigs[] = { SIGWINCH, SIGINT, SIGTERM, SIGHUP, SIGTSTP, SIGCONT };
    for (size_t i = 0; i < sizeof sigs / sizeof *sigs; i++) {
        int s = sigs[i];
        signal(s, SIG_IGN);
        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)s, 0, q);
        dispatch_source_set_event_handler(src, ^{
            if (s == SIGWINCH) { render(); return; }
            if (s == SIGTSTP) { restore(); signal(SIGTSTP, SIG_DFL); raise(SIGTSTP); return; }
            if (s == SIGCONT) { signal(SIGTSTP, SIG_IGN); raw_mode(1); render(); return; }
            restore();
            exit(0);
        });
        dispatch_resume(src);
    }
    dispatch_main();
}
