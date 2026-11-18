# Linux low-RAM desktop tuning

A field-tested set of tweaks for a Linux desktop that keeps running out of RAM (and sometimes CPU),
plus an idempotent script that applies them.

It was worked out on a 16 GB laptop (Intel Core i5-11400H "Tiger Lake-H", NVMe, Arch Linux, KDE
Plasma 6 on Wayland) whose day job is browsers, Electron apps, JVM builds and several AI-coding
sessions at once. Everything here is measured or sourced; the things that *didn't* pay off are listed
too, so you don't have to rediscover them.

```sh
git clone https://github.com/Migiht/linux-low-ram-tuning
cd linux-low-ram-tuning
./install.sh --dry-run      # show what would change
./install.sh                # apply everything (asks for sudo where needed)
./install.sh --only zswap,thp,mglru   # or pick components
```

Run `./install.sh --list` for the components. Every component is idempotent — re-running is safe —
and prints what it changed.

---

## Results at a glance

| Change | Effect on this machine |
|---|---|
| zswap + disk swap instead of a 4 GB zram | ~10–12 GB of cold pages fit compressed in 4 GB of RAM (measured 3.2× on desktop data); no more "zram full → hot pages to disk" stalls |
| THP `always` → `madvise` | no huge-page bloat for apps that never asked for it; no compaction stalls |
| MGLRU `min_ttl_ms=1000` | the working set is protected from thrashing under pressure |
| Lazy + gated MCP servers ([mcp-lazy](https://github.com/Migiht/mcp-lazy)) | ~125 MB → ~7 MB per idle AI-agent session per server; 135 tool names → 1 line of model context |
| Killing idle agent sessions, unused DB services | ~0.8–0.9 GB each round; 750 MB ClickHouse + 2 GB Postgres that ran for nothing |
| Baloo off, KWin effects off | no background indexer churn; fewer compositor wake-ups |
| Chrome with a renderer limit | caps the process explosion of many tabs |
| earlyoom with prefer/avoid rules | the browser or a build dies before the desktop does |

---

## Tier list

Ordered by payoff for a RAM-bound desktop, after reading the evidence for each.

### S — big win, near-zero risk

**1. Compressed swap done right: zswap in front of disk swap** (`zswap`)

The usual "zram of 4 GB + a swap file" is the worst of both: zram's size limit counts
*uncompressed* data (4 GB ≈ 1.3 GB of real RAM at 3:1), it fills up fast, everything after that goes
straight to disk — and because zram is just a swap device with no LRU, the pages stuck in it are the
*oldest* ones while the warmer, newer ones land on disk (LRU inversion).

zswap is a compressed cache *in front of* the swap file. Its limit is on the *compressed* pool, it
evicts the coldest pages to disk itself, and the shrinker writes cold pages back proactively.

```
zswap.enabled=1 zswap.compressor=zstd zswap.max_pool_percent=25 zswap.shrinker_enabled=1
vm.swappiness=100
```

`max_pool_percent=25` means *up to* 25 % of RAM for compressed pages (4 GB on 16 GB). It's a cap,
not a reservation — the pool is empty until something gets swapped. 20 for mostly-hot workloads,
30–35 for "lots of background windows"; past ~40 the compressed data starts evicting the working set.

Check: `grep -E 'Zswap|Zswapped' /proc/meminfo` — `Zswapped / Zswap` is your compression ratio.

When zram is still the right call: no disk swap at all, or slow storage (eMMC, SD). Then use
`zram-size = ram`, `vm.swappiness=180`, `vm.page-cluster=0`, `vm.watermark_boost_factor=0`,
`vm.watermark_scale_factor=125` (the ArchWiki set) — and never both zswap and zram.

**2. Transparent huge pages: `always` → `madvise`** (`thp`)

Arch ships THP `always`: any eligible anonymous mapping may get 2 MB pages, which inflates memory for
programs that touch a few bytes per huge page, and the compaction behind it can stall interactive
work. `madvise` keeps huge pages for those who ask (`MADV_HUGEPAGE`) — e.g. the JVM with
`-XX:+UseTransparentHugePages` — and nobody else.

**3. Stop what runs for nothing** (manual)

The biggest single wins were not kernel knobs:

- database servers left running as user services from an old project (ClickHouse 750 MB,
  Postgres 2 GB on disk) — `systemctl --user disable --now …`;
- idle AI-agent sessions: every open session keeps its CLI process (~150–250 MB) *plus its own copy
  of every MCP server*. Close sessions you aren't using;
- Docker daemons nobody used: switch to socket activation (`systemctl disable --now docker.service`,
  `systemctl enable docker.socket`).

Use `smem`/PSS, not the desktop "Applications" view — it hides CLIs, agents and their children.
A one-liner that groups PSS by program:

```sh
sudo bash -c 'for d in /proc/[0-9]*; do awk -v c="$(cat $d/comm 2>/dev/null)" "/^Pss:/{p=\$2} END{print p, c}" $d/smaps_rollup 2>/dev/null; done' \
  | awk '{s[$2]+=$1} END{for(k in s) printf "%7.0f MB %s\n", s[k]/1024, k}' | sort -rn | head -20
```

### A — clear payoff where it applies

**4. MGLRU thrashing protection** (`mglru`)

`min_ttl_ms=1000` stops the multi-gen LRU from evicting pages younger than one second: under memory
pressure the system keeps its working set and the OOM handler acts instead of the desktop freezing.
Needs `CONFIG_LRU_GEN` (on in Arch, Fedora, Ubuntu ≥ 23.10).

**5. earlyoom with sane prefer/avoid rules** (`earlyoom`)

Kills at 5 % free RAM + 10 % free swap, preferring browsers/Electron/JVM/compilers and never the
compositor, the shell, audio or systemd:

```
-m 5 -s 10 -r 3600 --prefer '(^|/)(firefox|chrome|chromium|electron|java|node|cc1plus|rustc|ld)$'
--avoid '(^|/)(init|systemd|systemd-.*|kwin_wayland|plasmashell|Xwayland|sddm|sddm-helper|pipewire|wireplumber|sshd|dbus-.*)$'
```

(If you prefer `systemd-oomd`, don't run both.)

**6. Lazy, gated MCP servers for AI coding agents** (`mcp-lazy`)

MCP clients such as Claude Code start every configured MCP server for every session. A Node-based
server costs ~100 MB per session even if the session never uses it, and a server with 135 tools puts
135 tool names plus its instructions into the model's context.
[mcp-lazy](https://github.com/Migiht/mcp-lazy) answers the connect-time handshake and tool lists
from a cache and starts the real server only on the first real call; with `--gate` the tools stay
hidden behind one `enable_tools` tool until the model needs them.

Measured: an idle session went from ~125 MB (npm + node) to ~7 MB per server; the model sees one
line instead of 135 tool names. The installer builds it with cargo and wraps every user-scope stdio
MCP server in `~/.claude.json` (backup first, wrapped servers skipped).

Point the wrapper at a local build of a server rather than `npx pkg@latest`: that avoids an extra
`npm` process and lets the cache notice upgrades (it fingerprints the files on the command line).

**7. Limit build parallelism by RAM, not by cores** (manual)

One `cc1plus` on a big C++ file took 1.45 GB here. `make -j12` on 16 GB is an OOM waiting to happen:
use `-j4`…`-j6`. Same for Gradle/Kotlin daemons: `org.gradle.jvmargs=-Xmx2g`,
`kotlin.daemon.jvmargs=-Xmx1g`, and `./gradlew --stop` when done.

### B — small but real

**8. KDE: Baloo off** (`baloo`) — the file indexer re-crawls home directories full of `node_modules`,
`target/` and build trees. `balooctl6 disable` + mask the user unit.

**9. KDE: heavy KWin effects off** (`kwin`) — blur, fades, slides, scale, squash, window aperture,
maximize/fullscreen animations. Fewer compositor frames, less GPU/CPU wake-up. (Separately, check
`AnimationDurationFactor` in `~/.config/kdeglobals`: `0` = instant, `1` = default, higher = *slower*.)

**10. Chrome with a renderer-process cap** (`chrome`)

A wrapper (`google-chrome-lite`) and a desktop entry that start Chrome with
`--renderer-process-limit=6 --js-flags=--max-old-space-size=256 --disable-smooth-scrolling`. Tabs
share renderers instead of one process each. The flags only apply when Chrome isn't already running.
Also turn on *Settings → Performance → Memory Saver*.

**11. A scheduler for responsiveness under load** (manual)

`sched_ext` ships in the stock Arch kernel: `scx_bpfland` (desktop) or `scx_lavd` (games) from
`scx-scheds` keep the UI smooth while a build pins every core. It doesn't add throughput, and it's
reversible with one command.

**12. EPP `performance` on AC** (manual)

`intel_pstate` EPP `balance_performance` → `performance` measured about +4 % performance for +22 %
power on a laptop. Worth it plugged in, if the laptop isn't already thermally throttling (check with
`turbostat`/`s-tui`; on H-series laptops cooling is often the real CPU limit).

### C — measurable only in benchmarks

- **`linux-zen` / `linux-cachyos`** kernels: slightly snappier, same throughput.
- **x86-64-v3 package repos** (CachyOS): 0–10 % in some packages; mixing repos complicates updates.
- **`vm.vfs_cache_pressure=50`, `nowatchdog`, `vm.dirty_*`**: noise.

### D — not worth it on this hardware

- **`mitigations=off`.** On Tiger Lake and newer most CPU vulnerabilities are *Not affected* in
  hardware; what's left (eIBRS, Spectre v1 barriers, BHI) is cheap. Phoronix measured Tiger Lake
  *slower* in places with mitigations off. Older CPUs (Skylake…Coffee Lake) are a different story —
  check `grep . /sys/devices/system/cpu/vulnerabilities/*` before deciding.

### F — don't

- `vm.swappiness=10` with zram/zswap — you paid for compressed swap and then forbid using it.
- No swap at all — the kernel then evicts page cache (your binaries) instead, and stalls earlier.
- `drop_caches` cron jobs and "RAM cleaners" — cache is free memory doing useful work.
- `nosmt` on a CPU that doesn't need it — loses half the threads.
- zswap *and* zram together — double compression for nothing.

---

## What the installer does, exactly

| Component | Files | Applied now | After reboot |
|---|---|---|---|
| `zswap` | kernel cmdline, `/etc/tmpfiles.d/zswap.conf`, `/etc/sysctl.d/99-swap.conf`; disables `zram-generator` config | yes (zram swapped off, zswap on) | cmdline + tmpfiles |
| `thp` | kernel cmdline, `/etc/tmpfiles.d/thp.conf` | yes | both |
| `mglru` | `/etc/tmpfiles.d/mglru-min-ttl.conf` | yes | yes |
| `earlyoom` | package, `/etc/default/earlyoom` | yes | service enabled |
| `baloo` | `balooctl6 disable`, masks `kde-baloo.service` (user) | yes | yes |
| `kwin` | `~/.config/kwinrc` `[Plugins]` | after `qdbus6 org.kde.KWin /KWin reconfigure` | yes |
| `chrome` | `~/.local/bin/google-chrome-lite`, `~/.local/share/applications/google-chrome-lite.desktop` | new Chrome launches | yes |
| `mcp-lazy` | `cargo install`, wraps user-scope stdio servers in `~/.claude.json` (backup kept) | new agent sessions | yes |

Kernel command line: the script edits `/etc/kernel/cmdline` (UKI; regenerates with `mkinitcpio -P`),
`/etc/default/grub` (regenerates `grub.cfg`), or systemd-boot entries in `/boot/loader/entries/`,
replacing existing values of the same keys (e.g. `zswap.enabled=0`). Each runtime setting is also
written as a tmpfiles rule, so it holds even if the command line is lost.

Not automated on purpose (machine-specific): which services to stop, which agent sessions are idle,
build parallelism, scheduler and EPP choices.

### Reverting

- kernel cmdline: the script keeps `<file>.bak-lowram` next to every file it edits;
- tmpfiles/sysctl: delete `/etc/tmpfiles.d/{zswap,thp,mglru-min-ttl}.conf`, `/etc/sysctl.d/99-swap.conf`;
- zram: rename `/etc/systemd/zram-generator.conf.disabled` back;
- Baloo: `systemctl --user unmask kde-baloo.service && balooctl6 enable`;
- KWin: re-enable effects in System Settings → Window Management → Desktop Effects;
- MCP: restore `~/.claude.json.bak-lowram`.

## Verify after reboot

```sh
cat /sys/module/zswap/parameters/{enabled,compressor,max_pool_percent}   # Y zstd 25
swapon --show                                                             # disk swap only, no zram
cat /sys/kernel/mm/transparent_hugepage/enabled                           # [madvise]
cat /sys/kernel/mm/lru_gen/min_ttl_ms                                     # 1000
systemctl is-active earlyoom                                              # active
```

## Sources

- Phoronix, [CPU security mitigations on Tiger Lake](https://www.phoronix.com/review/tiger-lake-mitigations)
- ArchWiki, [zram](https://wiki.archlinux.org/title/Zram)
- Chris Down, [zswap vs zram: when to use what](https://chrisdown.name/2026/03/24/zswap-vs-zram-when-to-use-what.html)
- Kernel docs, [Transparent Hugepage Support](https://www.kernel.org/doc/html/latest/admin-guide/mm/transhuge.html)
- CachyOS wiki, [sched-ext](https://wiki.cachyos.org/configuration/sched-ext/)
- Phoronix, [EPP tuning on Meteor Lake](https://www.phoronix.com/review/intel-meteorlake-epp)
- Phoronix, [CachyOS x86-64-v3/v4 repositories](https://www.phoronix.com/review/cachyos-x86-64-v3-v4)

## License

MIT
