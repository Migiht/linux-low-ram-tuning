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
| Thorium (CPU-tuned Chromium) as the default browser, plus a Thorium Lite launcher | no Google background services; Lite caps renderer processes for tab-heavy sessions; browser-drawn window frame, Thorium 2024 UI |
| IntelliJ IDEA / RustRover: trimmed plugins + "Lite" profiles | 78 / 51 unused bundled plugins off; Lite: no AI completion, Grazie, MCP or embedded Chromium (~0.5 GB, 9 processes), 1 GB heap instead of 2–3 GB, periodic GC, capped malloc arenas |
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
-m 5 -s 10 -r 3600 --prefer '(^|/)(firefox|thorium|chrome|chromium|electron|java|node|cc1plus|rustc|ld)$'
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

**8. JetBrains IDEs: fewer plugins, and a "Lite" profile** (`jetbrains`)

IntelliJ IDEA Ultimate ships with 162 bundled plugins enabled, RustRover with 113; a Java/Maven or
Rust project needs a fraction. Measured on RustRover with a three-project Cargo workspace open: ~2.5–2.9
GB RSS, plus the embedded Chromium (JCEF) — 9 more processes, ~0.5 GB. Broken down with `jcmd`:

| Part | Size |
|---|---|
| Java heap | filled to whatever `-Xmx` allows; **~530 MB live** after a forced GC |
| Class metadata (metaspace) | ~270 MB — the IDE's and plugins' code; settings barely move it |
| Threads (~165–180), GC, malloc arenas, JIT code | ~300 MB |
| Memory-mapped jars and `.so` | ~0.5 GB — counted in RSS, but the kernel drops these pages for free |

So a real floor for a JVM IDE with Rust support is ~1 GB of its own memory; everything above that is
heap the GC hasn't bothered to return, embedded Chromium, glibc slack, and how much code you open.

What *doesn't* help much on 2026.x: classic vmoptions "tuning". Most guides
([FoxxMD/intellij-jvm-options-explained](https://github.com/FoxxMD/intellij-jvm-options-explained),
[jordanmews/intellij_performance_settings](https://github.com/jordanmews/intellij_performance_settings),
[lixiaoliyubo/jetbrains-vmoptions-config](https://github.com/lixiaoliyubo/jetbrains-vmoptions-config))
date from 2016–2020, and some of their advice works *against* RAM: `-Xms` = `-Xmx` pins the whole heap,
`-XX:+UseG1GC` is already the default. JBR 25 already enables compact object headers and returns free
heap to the OS (`JbrShrinkingGcMaxHeapFreeRatio=40`). Swapping in another JVM (OpenJ9, a jlink'd JRE)
isn't an option either: the IDE relies on JetBrains Runtime APIs (windowing, fonts, Wayland, JCEF), and
jlink only shrinks disk size.

What does help:

- **Disable unused bundled plugins** — `disabled_plugins.txt` in the IDE's config directory, edited
  while the IDE is closed. The lists in [`jetbrains/`](jetbrains/) drop Spring, Jakarta EE, Quarkus,
  Micronaut, Ktor, Kubernetes, the JS/CSS/web stack, Qodana, Trainer, CJK language packs, foreign
  keymaps (and in RustRover Qt/QML and extra colour schemes). They keep Kotlin, Gradle, Maven, Docker,
  Database Tools (SQL highlighting and `// language=PostgreSQL` injections live there),
  Git/GitHub/GitLab, Deployment, Dev Containers and Remote Development. **Read the list before
  installing** — it's tuned for Java/Kotlin and Rust work.
- **Globally ignored folders** — Settings → Editor → File Types → Ignored Files and Folders gets
  [`node_modules`, `.next`, `.nuxt`, `.output`, `.turbo`, `.svelte-kit`, `.parcel-cache`, `.venv`](jetbrains/ignored-folders.txt)
  in every profile, so no project indexes them (one workspace here had 25k files of `node_modules`
  indexed as plain text). `target` stays visible on purpose: Rust needs the proc-macros and build-script
  output in it, and both IDEs already exclude it for *attached* Cargo/Maven projects — so attach every
  Cargo project in a workspace (a non-attached one put 11k `target/` files into the index).
- **A "Lite" profile per IDE** — a launcher that points the IDE at its own config/system/plugins
  directories (`IDEA_PROPERTIES` / `RUSTROVER_PROPERTIES`) and its own vmoptions (`*_VM_OPTIONS`),
  and sets `MALLOC_ARENA_MAX=2` (glibc otherwise keeps up to 8 arenas per core; with ~180 threads that
  is 100–300 MB of slack). The profile starts as a copy of your settings (licence included) and then
  lives on its own, with its own indexes. On top of the plugin list it disables local full-line AI
  completion (a separate process of a few hundred MB), ML ranking in completion and Search Everywhere,
  Grazie, the MCP server, debugger MCP and the Agent Client Protocol, and doesn't download shared
  indexes. Its vmoptions are the IDE's own with [these overrides](jetbrains/lite.vmoptions-overrides):

  | Option | Why |
  |---|---|
  | `-Xmx1024m` | ~2× the measured live data |
  | `-XX:G1PeriodicGCInterval=30000` | collect when idle and give the memory back |
  | `-XX:MinHeapFreeRatio=10 -XX:MaxHeapFreeRatio=30` | G1 shrinks the heap once >30 % is free instead of >70 % — a 60 %-free heap had been holding ~600 MB for nothing |
  | `-XX:SoftMaxHeapSize=640m` | soft ceiling G1 aims for; it can still grow to `-Xmx`, so no OOM risk |
  | `-Dfile-page-cache.cache-capacity-mb=100` | the "File cache" for index pages may grow to 600 MB by default ([PageCacheUtils.java](https://github.com/JetBrains/intellij-community/blob/master/platform/util/src/com/intellij/util/io/PageCacheUtils.java)) |
  | `-XX:TrimNativeHeapInterval=60000` | once a minute, return glibc malloc's reserve to the OS |
  | `-XX:ParallelGCThreads=4 -XX:ConcGCThreads=1` | fewer GC threads (up to 10 by default) |
  | `-XX:ReservedCodeCacheSize=256m`, `-XX:SoftRefLRUPolicyMSPerMB=50` | half the JIT cache; caches let go sooner |
  | `-Dide.browser.jcef.enabled=false` | no embedded Chromium (~0.5 GB) |
  | `-XX:+UseStringDeduplication` | identical strings stored once |
  | `-XX:TieredStopAtLevel=1` | C1-only JIT, less compiled-code memory |
  | `-Dvcs.log.index.enable=false` | the Git log index held ~380k commit objects |

  Measured on RustRover Lite, idle after start: the heap-shrinking and cache lines alone took the
  process's own memory from 1883 MB to ~1354 MB (RSS ~2.4 → ~1.9 GB); the heap now grows only when
  needed and shrinks back.
  Trade-offs: C1-only JIT makes indexing and inspections slower (the first flag to drop if it feels
  sluggish); without JCEF the Markdown preview loses features and browser-based tool windows are blank;
  without the Git log index history search is slower; if the IDE warns about low memory, go back to
  `-Xmx1536m`.
- **Fewer inspections on the fly** — out of the box RustRover runs 655 inspections in the editor, IDEA
  1614. [These 24](jetbrains/inspections-off.txt) go off in *Settings for New Projects*
  (`options/project.default.xml`) in every profile, so each project opened for the first time starts
  without them: spelling, Grazie, text language detection, duplicated code, JSON/YAML schema checks,
  SQL "no data source/dialect" (SQL highlighting stays), Markdown link/table checks, non-ASCII,
  http-vs-https, unstable API, vulnerable libraries, commented-out code, Javadoc — and in RustRover the
  **External Linter** (`cargo check`/`clippy` on the fly: four `rustc` processes, gigabytes, after every
  start; the template also sets its `runOnTheFly` off) and "new crate version available". Kept on:
  borrow and type checks, unused code, Java/Kotlin data-flow and nullability.
  JetBrains has no truly global inspection setting — profiles live in each project's
  `.idea/inspectionProfiles` — so the template only reaches projects opened for the first time; for an
  existing one, switch them off once in Settings → Editor → Inspections (or copy a
  `Project_Default.xml`). You can still run everything on demand: Code → Inspect Code.
- **Habits:**
  - open one project at a time, not a folder of several — a three-project Cargo workspace meant name
    maps for 1942 crates (~8 s at every start, and most of the heap); one project is about a third;
  - one IDE open at a time;
  - "Preparing data for name resolution" at every RustRover start is normal — it's rebuilt in memory,
    not re-indexing; "Analyzing project" re-indexes only when caches were wiped or build output changed;
  - turning off proc-macro expansion or Cargo-check external linters saves memory and CPU but costs
    completion for macro-generated code / on-the-fly errors — a conscious trade;
  - IDE caches (`~/.cache/JetBrains`) grow to several GB per IDE; deleting them (IDE closed) frees disk,
    not RAM, and costs a full re-index;
  - File → Power Save Mode when you only read code.

`JETBRAINS_TRIM_MAIN=0 ./install.sh --only jetbrains` adds the Lite profiles without touching the normal
ones. Close the IDEs first — they rewrite `disabled_plugins.txt` and `filetypes.xml` on exit; the
installer skips those for running IDEs.

### B — small but real

**9. KDE: Baloo off** (`baloo`) — the file indexer re-crawls home directories full of `node_modules`,
`target/` and build trees. `balooctl6 disable` + mask the user unit.

**10. KDE: heavy KWin effects off** (`kwin`) — blur, fades, slides, scale, squash, window aperture,
maximize/fullscreen animations. Fewer compositor frames, less GPU/CPU wake-up. (Separately, check
`AnimationDurationFactor` in `~/.config/kdeglobals`: `0` = instant, `1` = default, higher = *slower*.)

**11. Thorium as the browser, plus Thorium Lite** (`thorium`)

[Thorium](https://github.com/Alex313031/thorium) is a Chromium build compiled for the CPU's instruction
set (AVX2/AVX/SSE3) — same engine and extensions as Chrome, without Google's background services. The
installer gets it from the AUR (`thorium-browser-bin`, via paru/yay) on Arch, or the matching
`.deb`/`.rpm` from the latest GitHub release elsewhere, and makes it the default browser
(`xdg-settings`, `xdg-mime` for http/https/html, and Plasma's own `BrowserApplication`;
`THORIUM_DEFAULT_BROWSER=0` keeps your current default).

The normal Thorium runs with its own defaults — no extra command-line flags — and stays the default
browser. Next to it the installer adds **Thorium Lite**: a `thorium-lite` launcher and a "Thorium
Browser (Lite)" menu entry that start the same profile with `--renderer-process-limit=6
--js-flags=--max-old-space-size=256 --disable-smooth-scrolling`. Tabs then share six renderer processes
instead of one each, and a runaway page's JS heap is capped — use it for tab-heavy sessions. The flags
only apply if Thorium isn't already running (otherwise the window opens in the running browser).
`THORIUM_LITE=0` skips it; `THORIUM_RENDERER_LIMIT` changes the cap.

UI: the browser draws its own title bar and window buttons instead of the window manager's
(`browser.custom_chrome_frame`), with the classic theme rather than GTK/Qt and the **Thorium 2024** UI
(`chrome://flags/#thorium-2024`). The installer sets these in every profile — or seeds them before the
first start — while Thorium is closed (it rewrites its files on exit).

Also turn on *Settings → Performance → Memory Saver*.

**12. A scheduler for responsiveness under load** (manual)

`sched_ext` ships in the stock Arch kernel: `scx_bpfland` (desktop) or `scx_lavd` (games) from
`scx-scheds` keep the UI smooth while a build pins every core. It doesn't add throughput, and it's
reversible with one command.

**13. EPP `performance` on AC** (manual)

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
| `thorium` | AUR / GitHub release package; `~/.local/bin/thorium-lite` + `thorium-lite.desktop`; `Preferences` + `Local State` of every profile; default browser via `xdg-settings`/`xdg-mime`/`kdeglobals` | new Thorium launches; settings after it's closed | yes |
| `jetbrains` | `disabled_plugins.txt`, `options/filetypes.xml` and `options/project.default.xml` of the newest IDEA/RustRover profile; a `<profile>-lite` copy; `~/.config/JetBrains/lite/*-lite.{properties,vmoptions}`; `~/.local/bin/*-lite`; `jetbrains-*-lite.desktop` | next IDE start | yes |
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
- Thorium: delete `~/.local/bin/thorium-lite` and `~/.local/share/applications/thorium-lite.desktop`; restore `Preferences.bak-lowram` / `Local State.bak-lowram`; pick another default browser in System Settings;
- MCP: restore `~/.claude.json.bak-lowram`;
- JetBrains: restore `disabled_plugins.txt.bak-lowram` in the profile (or re-enable plugins in Settings → Plugins); delete the `*-lite` profile directories, launchers and desktop entries.

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
- JetBrains JVM options: [FoxxMD/intellij-jvm-options-explained](https://github.com/FoxxMD/intellij-jvm-options-explained), [jordanmews/intellij_performance_settings](https://github.com/jordanmews/intellij_performance_settings), [lixiaoliyubo/jetbrains-vmoptions-config](https://github.com/lixiaoliyubo/jetbrains-vmoptions-config) (mostly pre-2021 — read with the caveats above)
- JetBrains, [Advanced configuration: JVM options, platform properties, config directories](https://www.jetbrains.com/help/idea/tuning-the-ide.html)
- JetBrains support, [The IDE uses more memory than -Xmx](https://intellij-support.jetbrains.com/hc/en-us/articles/360018776919)
- JetBrains, [intellij-community `PageCacheUtils.java`](https://github.com/JetBrains/intellij-community/blob/master/platform/util/src/com/intellij/util/io/PageCacheUtils.java) (file page cache sizing)
- Baeldung, [Reduce IntelliJ IDEA memory usage](https://www.baeldung.com/java-intellij-reduce-memory)
- JetBrains, [RustRover performance tuning: filter the list of inspections](https://www.jetbrains.com/help/rust/code-inspection.html)
- Phoronix, [CachyOS x86-64-v3/v4 repositories](https://www.phoronix.com/review/cachyos-x86-64-v3-v4)

## License

MIT
