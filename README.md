# Mem

A single-window memory monitor for macOS. It shows the same numbers as Activity Monitor's Memory tab, at a third of the size, and does no work while idle.

- **System totals**: used, app, wired, compressed, cached files, free, swap and memory pressure. These come from `host_statistics64` and `sysctl`, the same counters Activity Monitor reads.
- **Every process with its physical footprint**: the same figure as Activity Monitor's "Memory" column. Sort by name, memory or PID, and filter by name or PID.
- **Quit / Force Quit** from each row's right-click menu, with a confirmation.

## Cost

Measured on an M-series Mac running macOS 15.7, with about 500 processes:

| | Mem | Activity Monitor |
|---|---|---|
| Footprint | 14–18 MB | 52 MB + `sysmond` 2 MB |
| CPU while idle | 0 (no timer) | polls every 1–5 s |
| Refresh | 0.4 ms direct reads + 1.4 ms `memread` | — |

The floor for any AppKit window is about 11–12 MB.

**No polling.** Mem refreshes only when:
- memory pressure changes level (a kernel push event),
- an app launches or quits,
- the window comes to the front,
- you press ⌘R.

It skips refreshes entirely while the window is hidden.

## Root-owned processes

macOS won't let an unprivileged app read the memory of root-owned processes such as WindowServer, mds and launchd. That's about a third of the list. Mem gets those numbers in one of two ways:

1. **`memread`** (recommended). This repo includes a 34 KB setuid-root helper (`memread.c`). It takes no arguments, reads no input, prints `pid footprint` for every process, drops privileges before writing, and exits. It costs 1.4 ms of CPU and peaks at about 1 MB. Install it once with `./build.sh --install-helper`.
2. **`/usr/bin/top`** (fallback). Without the helper, Mem runs one `top` snapshot per refresh. That costs about 100 ms of CPU.

Mem uses `memread` only if `/usr/local/libexec/memread` is owned by root and has the setuid bit set.

## Build

Requires the Xcode command-line tools (`swiftc`, `cc`).

```sh
./build.sh                   # build Mem.app and memread
./build.sh --install         # also copy Mem.app to ~/Applications
./build.sh --install-helper  # also install memread setuid root (sudo)
./build.sh --package         # also zip both into dist/
```

`Mem.app/Contents/MacOS/Mem --dump` prints the totals and the top 12 processes to stdout, for checking numbers against `top`.

## Design notes

These choices were measured, not guessed:
- **App names** come from the executable path (the innermost `.app`), not `NSRunningApplication`. That saves about 5 MB of LaunchServices data.
- **The process list is an `NSTableView`.** A custom-drawn list was tried and cost 8 MB more: it needed one GPU-backed image the size of the whole list, while the table only creates views for the visible rows.
- **There's no User column.** Mem only tracks whether you own each process, which Quit uses to explain permission errors.
- **Polling vs events:** a 2-second poll cost 4.2 s of CPU per minute with `top` (7% of a core), with no memory benefit.
