```
 ███╗   ███╗███████╗███╗   ███╗
 ████╗ ████║██╔════╝████╗ ████║
 ██╔████╔██║█████╗  ██╔████╔██║
 ██║╚██╔╝██║██╔══╝  ██║╚██╔╝██║
 ██║ ╚═╝ ██║███████╗██║ ╚═╝ ██║
 ╚═╝     ╚═╝╚══════╝╚═╝     ╚═╝
 a memory monitor that doesn't eat memory
```

Mem is a memory monitor for macOS, in two forms:
- **Mem.app**: a single native window, about 18 MB.
- **`mem`**: a terminal UI, about 1.5 MB.

Both show what Activity Monitor's Memory tab shows, and neither does anything while you aren't looking at it.

```
┌─ Mem ──────────────── 521 processes · this app 18 MB · ⌘R ─┐
│ Used          9.04 GB of 16.00 GB   Pressure  Normal · 80% │
│ ● App               6.00 GB         ● Wired        2.16 GB │
│ ● Compressed         899 MB         ● Cached files 4.78 GB │
│ Free                2.62 GB         Swap   669 MB on disk  │
│ [▓▓▓▓▓████████████████████░░░░░░░░░░░░░░░░░░             ] │
│ ┌─────────────────────────────────────────────────────────┐│
│ │ Filter processes                                        ││
│ └─────────────────────────────────────────────────────────┘│
│  Process                              Memory ▼       PID   │
│  Xcode                                1.07 GB        801   │
│  Firefox                               437 MB       2586   │
│  Firefox GPU Helper                    423 MB       2588   │
│  WindowServer                          381 MB        393   │
│  Terminal                              337 MB       1000   │
└────────────────────────────────────────────────────────────┘
```

## `mem` in the terminal

```
 mem  used 9.89 GB of 16.00 GB   pressure Normal · 78% free   535 procs · 06:00:34
 ● app 6.66 GB  ● wired 2.39 GB  ● compressed 862 MB  ● cached 5.11 GB  free 1.20 GB
 ██████████████████████████████████████████████████████████████████████████░░░░░░░░
     PID      MEMORY▼  PROCESS
     801     1.07 GB   Xcode
    2588      581 MB   Firefox GPU Helper
    2586      450 MB   Firefox
     393      384 MB   WindowServer
    1000      342 MB   Terminal
 q quit  r refresh  ↑↓/jk move  s sort  / filter  x quit process  X force quit
```

`mem` is plain C with raw ANSI escapes (no ncurses), compiled to a 55 KB binary. It reads the same kernel counters and uses the same `memread` helper as the app.

| key            | does                                      |
|----------------|-------------------------------------------|
| `↑↓` `jk`      | move                                      |
| `PgUp/PgDn` `g/G` `space` | page, top, bottom              |
| `s`            | cycle sort: memory ▼, name ▲, PID ▲       |
| `/`            | filter by name or PID (`Esc` clears)      |
| `r`            | re-read everything                        |
| `x` / `X`      | quit / force quit the selected process (asks y/n) |
| `q`            | exit                                      |

The screen redraws on keys and terminal resizes. The data is re-read on `r`, when the kernel reports a memory-pressure change, and after you quit a process. Each refresh shows the time it ran, so you can always see how fresh the numbers are.

```sh
mem -1          # print one snapshot (top 25) and exit
mem -1 -n 50    # top 50
mem -a | less   # every process; piped output is plain text without colors
```

## Why

Activity Monitor runs at about 52 MB, plus a root helper, `sysmond`. It re-reads every process every 1–5 seconds whether anything changed or not; on the machine this was built on, `sysmond` had used 58 minutes of CPU. Mem answers the same question (*where did my RAM go?*) for less:

|                    | `mem` (terminal)    | Mem.app             | Activity Monitor          |
|--------------------|---------------------|---------------------|---------------------------|
| Footprint          | **~1.5 MB**         | **~18 MB**          | ~52 MB + `sysmond` ~2 MB  |
| CPU while idle     | **0**               | **0**               | polls every 1–5 s         |
| Cost of a refresh  | ~2 ms               | 0.4 ms + 1.5 ms `memread` | —                   |
| Root processes     | yes (`memread`)     | yes (`memread`)     | yes (`sysmond`)           |

Measured on an Apple M4 running macOS 15.7, with about 520 processes. Any AppKit window costs about 11–12 MB, so Mem.app's own code accounts for about 6 MB of its total. `mem` has no window, so it doesn't pay that floor.

## What it shows

- **Totals**: used, app, wired, compressed, cached files, free, swap, and memory pressure with the kernel's free percentage. These come from `host_statistics64` and `sysctl`, with the same breakdown Activity Monitor uses.
- **Every process with its physical footprint**: the "Memory" column in Activity Monitor, and the number macOS actually charges a process for. You can sort by name, memory or PID, and filter by name or PID.
- **Right-click any row** to Quit or Force Quit it, with a confirmation.

## No polling

```
   memory pressure changes ─┐
   an app launches/quits  ──┤
   window comes forward   ──┼──▶  refresh  ──▶  idle (0 CPU)
   ⌘R                     ──┘
```

Mem has no timer. It refreshes only when one of the events above happens, and skips the work while its window is hidden. Measured over a minute: a 2-second poll cost **4.2 s of CPU** (about 7% of a core) and saved no memory. The event-driven build used 0.35 s, all of it during startup.

## Root-owned processes

macOS won't let an ordinary app read the memory of root-owned processes such as WindowServer, mds and launchd. That's about a third of the list. Mem fills those in one of two ways:

```
 your processes ──── proc_pid_rusage ───────────────────────┐
                                                            ├──▶ table
 root processes ──── memread (setuid, 1.5 ms, ~1 MB peak) ──┤
                 └── /usr/bin/top (fallback, ~100 ms) ──────┘
```

`memread` is a 34 KB setuid-root helper (`memread.c`, about 30 lines):
- It takes no arguments and reads no input.
- It prints `pid footprint` for every process.
- It drops root privileges before writing anything, then exits.

Its output is information `top` already shows every user. Mem uses it only if `/usr/local/libexec/memread` exists, is owned by root and has the setuid bit set. Otherwise it falls back to one `top` snapshot per refresh, which costs about 70× more CPU.

## Install

You need the Xcode command-line tools (`swiftc`, `cc`).

```sh
git clone https://github.com/quivent/mem.git && cd mem
make                  # build Mem.app, mem and memread
make install          # copy Mem.app to ~/Applications
make install-cli      # copy mem to ~/.local/bin (BINDIR=... to change)
make install-helper   # one-time: install memread setuid root (sudo)
```

Rerun `make install-helper` only if `memread.c` changes.

| target                | does                                           |
|-----------------------|------------------------------------------------|
| `make`                | build `Mem.app`, `mem` and `memread`           |
| `make install`        | copy `Mem.app` to `~/Applications`             |
| `make install-cli`    | copy `mem` to `~/.local/bin`                   |
| `make install-helper` | install `memread` setuid root (one-time, sudo) |
| `make uninstall`      | remove all three                               |
| `make package`        | zip all three into `dist/Mem-<version>.zip`    |
| `make dump`           | print totals and the top processes to stdout   |
| `make clean`          | remove build output                            |

## Design notes

Each of these choices was measured, not guessed:

- **Names come from the executable path** (the innermost `.app` bundle), not `NSRunningApplication`. The latter pulls LaunchServices data into memory for every app. **−5 MB.**
- **The process list is a plain `NSTableView`.** A custom-drawn list was tried and came out **+8 MB**: it needed one GPU-backed image the size of the whole list, while the table only creates views for the rows on screen.
- **No Metal.** A Metal-rendered window would keep 2–3 window-sized frames of its own plus a glyph texture. AppKit already composites on the GPU, and the 11–12 MB floor is the window itself, not how it's drawn.
- **No User column.** Mem only tracks whether you own each process, which Quit uses to explain permission errors.
- **`mem` is C, not Swift.** It needs no runtime and no frameworks beyond libSystem, uses libdispatch sources for stdin, signals and memory-pressure events, and does one `write()` per frame.
- **Heap:** about 4 MB of live allocations, mostly AppKit and Core Foundation bookkeeping. The process list itself is tens of KB.

## License

MIT
