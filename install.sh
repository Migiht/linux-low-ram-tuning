#!/usr/bin/env bash
# Low-RAM desktop tuning — see README.md for what each component does and why.
#
#   ./install.sh                     apply every component
#   ./install.sh --dry-run           print what would change, change nothing
#   ./install.sh --only zswap,thp    apply only these components
#   ./install.sh --skip kwin         apply all but these
#   ./install.sh --list              list components
#
# Run as your normal user: system parts use sudo, user parts (KDE, Chrome, MCP) need your $HOME.
# Every component is idempotent; every file it rewrites is backed up once as <file>.bak-lowram.
set -euo pipefail

COMPONENTS=(zswap thp mglru earlyoom baloo kwin thorium jetbrains mcp-lazy)
ROOT_COMPONENTS=(zswap thp mglru earlyoom)
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
declare -A DESCRIPTION=(
  [zswap]="zswap (zstd, 25% pool, shrinker) in front of disk swap; zram off; swappiness 100"
  [thp]="transparent huge pages: madvise instead of always"
  [mglru]="MGLRU thrashing protection: min_ttl_ms=1000"
  [earlyoom]="earlyoom with prefer (browsers, JVM, compilers) / avoid (desktop, audio) rules"
  [baloo]="KDE: disable the Baloo file indexer"
  [kwin]="KDE: disable heavy KWin effects"
  [thorium]="Thorium as the default browser (custom window frame, Thorium 2024 UI) + a renderer-capped Thorium Lite launcher"
  [jetbrains]="IntelliJ IDEA / RustRover: trim plugins; add Lite profiles (no AI completion, Grazie, MCP; 1 GB heap)"
  [mcp-lazy]="AI agents: build mcp-lazy and wrap user-scope stdio MCP servers in ~/.claude.json"
)

ZSWAP_POOL_PERCENT=${ZSWAP_POOL_PERCENT:-25}
SWAPPINESS=${SWAPPINESS:-100}
MGLRU_MIN_TTL_MS=${MGLRU_MIN_TTL_MS:-1000}
THORIUM_RENDERER_LIMIT=${THORIUM_RENDERER_LIMIT:-6}
MCP_LAZY_FLAGS=${MCP_LAZY_FLAGS:---gate --per-cwd}
MCP_LAZY_REPO=${MCP_LAZY_REPO:-https://github.com/Migiht/mcp-lazy}
EARLYOOM_ARGS_DEFAULT="-m 5 -s 10 -r 3600 --prefer '(^|/)(firefox|thorium|chrome|chromium|electron|java|node|cc1plus|rustc|ld)\$' --avoid '(^|/)(init|systemd|systemd-.*|kwin_wayland|plasmashell|Xwayland|sddm|sddm-helper|pipewire|wireplumber|sshd|dbus-.*)\$'"
EARLYOOM_ARGS=${EARLYOOM_ARGS:-$EARLYOOM_ARGS_DEFAULT}
KWIN_EFFECTS=(blur fadingpopups frozenapp fullscreen maximize scale screenedge slide slidingnotifications slidingpopups squash windowaperture)
THORIUM_DEFAULT_BROWSER=${THORIUM_DEFAULT_BROWSER:-1}   # 0: install and tune Thorium, keep the current default browser
THORIUM_LITE=${THORIUM_LITE:-1}                         # 0: no Thorium Lite launcher
THORIUM_DESKTOP_SRC=${THORIUM_DESKTOP_SRC:-/usr/share/applications/thorium-browser.desktop}
JETBRAINS_TRIM_MAIN=${JETBRAINS_TRIM_MAIN:-1}   # 0: leave the normal IDE profiles alone, only add Lite ones
JETBRAINS_ROOTS=${JETBRAINS_ROOTS:-}            # extra colon-separated directories to look for IDE installs in

DRY=0
PENDING_CMDLINE=()   # kernel parameters collected by components, applied once at the end
CHANGED=0

# ───────────────────────────── output ─────────────────────────────

if [[ -t 1 ]]; then B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' D=$'\e[2m' N=$'\e[0m'; else B='' G='' Y='' R='' D='' N=''; fi
section() { printf '\n%s== %s%s\n' "$B" "$1" "$N"; }
ok()      { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
same()    { printf '  %s· %s%s\n' "$D" "$*" "$N"; }
warn()    { printf '  %s! %s%s\n' "$Y" "$*" "$N" >&2; }
indent()  { local l; while IFS= read -r l; do printf '      %s\n' "$l"; done; }
die()     { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# Run a command (prefixed with sudo when $1 is "root"), or just print it in dry-run mode.
run() {
  local who=$1; shift
  if ((DRY)); then printf '  %s[dry-run]%s %s%s\n' "$D" "$N" "$([[ $who == root ]] && echo 'sudo ')" "$*"; return 0; fi
  if [[ $who == root && $EUID -ne 0 ]]; then sudo "$@"; else "$@"; fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# ───────────────────────────── files ─────────────────────────────

# write_file <root|user> <path> <content>: write if different; back the old file up once.
WROTE=0   # set by write_file: 1 if the last call changed (or would change) the file
write_file() {
  local who=$1 path=$2 content=$3 current=""
  WROTE=0
  if [[ $who == root ]]; then current=$(sudo cat "$path" 2>/dev/null || true); else current=$(cat "$path" 2>/dev/null || true); fi
  if [[ "$current" == "$content" ]]; then same "$path unchanged"; return 0; fi
  CHANGED=1 WROTE=1
  if ((DRY)); then
    local lines; lines=$(wc -l <<<"$content")
    printf '  %s[dry-run]%s write %s:\n' "$D" "$N" "$path"
    if ((lines > 12)); then head -n 8 <<<"$content" | indent; printf '      … (%d lines)\n' "$lines"
    else indent <<<"$content"; fi
    return 0
  fi
  if [[ -n "$current" && ! -e "$path.bak-lowram" ]]; then run "$who" cp -p "$path" "$path.bak-lowram"; fi
  run "$who" mkdir -p "$(dirname "$path")"
  if [[ $who == root && $EUID -ne 0 ]]; then printf '%s\n' "$content" | sudo tee "$path" >/dev/null
  else printf '%s\n' "$content" >"$path"; fi
  ok "wrote $path"
}

# Write a sysfs value now (best effort; the tmpfiles rule makes it persistent).
sysfs_set() {
  local path=$1 value=$2
  [[ -e $path ]] || { warn "$path not present on this kernel"; return 0; }
  if [[ "$(cat "$path" 2>/dev/null)" == *"[$value]"* || "$(cat "$path" 2>/dev/null)" == "$value" ]]; then same "$path = $value"; return 0; fi
  if ((DRY)); then run root sh -c "echo $value > $path"; return 0; fi
  if echo "$value" | sudo tee "$path" >/dev/null 2>&1; then ok "$path = $value (now)"; else warn "could not set $path now; it applies after reboot"; fi
}

# ───────────────────────────── kernel command line ─────────────────────────────

# set_params "<cmdline>" key=value... → the cmdline with every key set to the given value: an
# existing `key=...` or bare `key` is replaced in place, a missing one is appended.
set_params() {
  local line=$1; shift
  local -a words
  read -r -a words <<<"$line"
  local kv key i found
  for kv in "$@"; do
    key=${kv%%=*}; found=0
    for i in "${!words[@]}"; do
      if [[ ${words[$i]} == "$key" || ${words[$i]} == "$key="* ]]; then
        if ((found)); then unset 'words[i]'; else words[i]=$kv; found=1; fi
      fi
    done
    ((found)) || words+=("$kv")
  done
  echo "${words[*]}"
}

apply_cmdline() {
  ((${#PENDING_CMDLINE[@]})) || return 0
  section "kernel command line"
  local params=("${PENDING_CMDLINE[@]}")

  if [[ -f /etc/kernel/cmdline ]]; then
    # Unified kernel images (mkinitcpio, dracut, kernel-install) read this file.
    local cur new; cur=$(cat /etc/kernel/cmdline); new=$(set_params "$cur" "${params[@]}")
    if [[ "$cur" == "$new" ]]; then same "/etc/kernel/cmdline already has ${params[*]}"; return 0; fi
    write_file root /etc/kernel/cmdline "$new"
    if have mkinitcpio && grep -qs '_uki=' /etc/mkinitcpio.d/*.preset; then run root mkinitcpio -P
    elif have dracut; then run root dracut --regenerate-all --force
    elif have kernel-install; then
      local k; for k in /usr/lib/modules/*/vmlinuz; do run root kernel-install add "$(basename "$(dirname "$k")")" "$k"; done
    else warn "rebuild your unified kernel image so it picks up /etc/kernel/cmdline"; fi
    return 0
  fi

  if have grubby; then
    # Fedora/RHEL: grubby edits every boot entry.
    run root grubby --update-kernel=ALL --args="${params[*]}"
    return 0
  fi

  if [[ -f /etc/default/grub ]]; then
    local cur new
    cur=$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' /etc/default/grub)
    new=$(set_params "$cur" "${params[@]}")
    if [[ "$cur" == "$new" ]]; then same "GRUB already has ${params[*]}"; return 0; fi
    local content
    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
      content=$(NEW="$new" awk '/^GRUB_CMDLINE_LINUX_DEFAULT=/{print "GRUB_CMDLINE_LINUX_DEFAULT=\"" ENVIRON["NEW"] "\""; next} {print}' /etc/default/grub)
    else
      content=$(cat /etc/default/grub; echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$new\"")
    fi
    write_file root /etc/default/grub "$content"
    if have update-grub; then run root update-grub
    elif have grub-mkconfig; then run root grub-mkconfig -o /boot/grub/grub.cfg
    elif have grub2-mkconfig; then run root grub2-mkconfig -o /boot/grub2/grub.cfg
    else warn "regenerate grub.cfg yourself"; fi
    return 0
  fi

  local entries; entries=$(sudo sh -c 'ls /boot/loader/entries/*.conf 2>/dev/null' || true)
  if [[ -n "$entries" ]]; then
    local e cur new content
    for e in $entries; do
      cur=$(sudo sed -n 's/^options[[:space:]]\+//p' "$e")
      new=$(set_params "$cur" "${params[@]}")
      [[ "$cur" == "$new" ]] && { same "$e already set"; continue; }
      content=$(sudo cat "$e" | NEW="$new" awk '/^options[[:space:]]/{print "options " ENVIRON["NEW"]; next} {print}')
      write_file root "$e" "$content"
    done
    return 0
  fi

  warn "unknown boot setup — add these kernel parameters yourself: ${params[*]}"
  warn "(the tmpfiles rules already apply the same settings at boot)"
}

# ───────────────────────────── components ─────────────────────────────

c_zswap() {
  [[ -d /sys/module/zswap ]] || { warn "this kernel has no zswap — skipped"; return 0; }

  # zswap needs a real swap device behind it. Never leave the system without swap.
  local disk_swap
  disk_swap=$(awk 'NR>1 && $1 !~ /zram/ {print $1}' /proc/swaps)
  if [[ -z "$disk_swap" ]]; then
    warn "no disk swap found: zswap needs a swap file or partition behind it."
    warn "create one first, e.g.:  sudo mkswap -U clear --size 16G --file /swapfile && sudo swapon /swapfile"
    warn "and add '/swapfile none swap defaults 0 0' to /etc/fstab — then re-run. zswap skipped."
    return 0
  fi
  ok "disk swap: $(tr '\n' ' ' <<<"$disk_swap")"

  PENDING_CMDLINE+=("zswap.enabled=1" "zswap.compressor=zstd" "zswap.max_pool_percent=$ZSWAP_POOL_PERCENT" "zswap.shrinker_enabled=1")
  write_file root /etc/tmpfiles.d/zswap.conf "# zswap is also set on the kernel command line; this keeps it on if that is lost.
w- /sys/module/zswap/parameters/compressor       - - - - zstd
w- /sys/module/zswap/parameters/max_pool_percent - - - - $ZSWAP_POOL_PERCENT
w- /sys/module/zswap/parameters/shrinker_enabled - - - - Y
w- /sys/module/zswap/parameters/enabled          - - - - Y"
  write_file root /etc/sysctl.d/99-swap.conf "vm.swappiness = $SWAPPINESS"
  if [[ "$(cat /proc/sys/vm/swappiness)" != "$SWAPPINESS" ]]; then run root sysctl -q -w "vm.swappiness=$SWAPPINESS"; fi

  # zram and zswap together means compressing twice: retire zram.
  local f
  for f in /etc/systemd/zram-generator.conf /usr/lib/systemd/zram-generator.conf; do
    [[ -f $f ]] || continue
    if [[ $f == /usr/* ]]; then
      # Package default (e.g. Fedora's zram-generator-defaults): override with an empty config.
      write_file root /etc/systemd/zram-generator.conf "# zram disabled: zswap + disk swap is used instead"
    else
      grep -q '^\[zram' "$f" && { run root mv "$f" "$f.disabled"; ok "zram-generator config → $f.disabled"; CHANGED=1; }
    fi
  done
  local dev
  while read -r dev; do
    run root swapoff "$dev" && ok "swapped off $dev"
  done < <(awk 'NR>1 && $1 ~ /zram/ {print $1}' /proc/swaps)

  sysfs_set /sys/module/zswap/parameters/compressor zstd
  sysfs_set /sys/module/zswap/parameters/max_pool_percent "$ZSWAP_POOL_PERCENT"
  [[ -e /sys/module/zswap/parameters/shrinker_enabled ]] && sysfs_set /sys/module/zswap/parameters/shrinker_enabled Y
  sysfs_set /sys/module/zswap/parameters/enabled Y
}

c_thp() {
  [[ -e /sys/kernel/mm/transparent_hugepage/enabled ]] || { warn "no THP on this kernel — skipped"; return 0; }
  PENDING_CMDLINE+=("transparent_hugepage=madvise")
  write_file root /etc/tmpfiles.d/thp.conf "# THP is also set on the kernel command line; this keeps it if that is lost.
w- /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise"
  sysfs_set /sys/kernel/mm/transparent_hugepage/enabled madvise
}

c_mglru() {
  [[ -e /sys/kernel/mm/lru_gen/min_ttl_ms ]] || { warn "kernel without MGLRU (CONFIG_LRU_GEN) — skipped"; return 0; }
  write_file root /etc/tmpfiles.d/mglru-min-ttl.conf "w- /sys/kernel/mm/lru_gen/min_ttl_ms - - - - $MGLRU_MIN_TTL_MS"
  sysfs_set /sys/kernel/mm/lru_gen/min_ttl_ms "$MGLRU_MIN_TTL_MS"
}

c_earlyoom() {
  if systemctl is-active -q systemd-oomd 2>/dev/null; then
    warn "systemd-oomd is active — running two OOM daemons fights; disable one (sudo systemctl disable --now systemd-oomd)"
  fi
  if ! have earlyoom; then
    if have pacman; then run root pacman -S --needed --noconfirm earlyoom
    elif have apt-get; then run root apt-get install -y earlyoom
    elif have dnf; then run root dnf install -y earlyoom
    elif have zypper; then run root zypper --non-interactive install earlyoom
    else warn "install earlyoom with your package manager, then re-run"; return 0; fi
  fi
  write_file root /etc/default/earlyoom "EARLYOOM_ARGS=\"$EARLYOOM_ARGS\""
  if [[ "$(systemctl is-enabled earlyoom.service 2>/dev/null)" != enabled ]]; then run root systemctl enable earlyoom.service; CHANGED=1; fi
  if ((WROTE)) || ! systemctl is-active -q earlyoom.service; then run root systemctl restart earlyoom.service
  else same "earlyoom running with these rules"; fi
}

c_baloo() {
  local ctl=""; have balooctl6 && ctl=balooctl6; [[ -z $ctl ]] && have balooctl && ctl=balooctl
  if [[ -z $ctl ]]; then same "Baloo not installed — nothing to do"; return 0; fi
  if have kreadconfig6 && [[ "$(kreadconfig6 --file baloofilerc --group "Basic Settings" --key "Indexing-Enabled")" != false ]]; then
    run user kwriteconfig6 --file baloofilerc --group "Basic Settings" --key "Indexing-Enabled" false
    run user "$ctl" disable >/dev/null 2>&1 || true
    CHANGED=1
  fi
  if systemctl --user cat kde-baloo.service >/dev/null 2>&1; then
    if [[ "$(systemctl --user is-enabled kde-baloo.service 2>/dev/null)" == masked ]]; then same "kde-baloo.service already masked"
    else run user systemctl --user mask --now kde-baloo.service; ok "kde-baloo.service masked"; CHANGED=1; fi
  fi
  ok "Baloo indexing disabled"
}

c_kwin() {
  have kwriteconfig6 || { same "not KDE Plasma 6 (no kwriteconfig6) — skipped"; return 0; }
  local e cur changed=0
  for e in "${KWIN_EFFECTS[@]}"; do
    cur=$(kreadconfig6 --file kwinrc --group Plugins --key "${e}Enabled" 2>/dev/null || true)
    [[ $cur == false ]] && continue
    run user kwriteconfig6 --file kwinrc --group Plugins --key "${e}Enabled" false
    changed=1
  done
  if ((changed)); then
    CHANGED=1; ok "disabled KWin effects: ${KWIN_EFFECTS[*]}"
    local q; for q in qdbus6 qdbus; do have $q && { run user $q org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true; break; }; done
  else same "KWin effects already off"; fi
}

# Thorium's settings: the browser draws its own title bar (not the window manager's), classic theme
# (not GTK/Qt), and the "Thorium 2024" UI flag. Applied to every existing profile, or seeded for the
# first run. The browser must be closed — it rewrites these files on exit.
thorium_prefs() {
  local dir=$1 report
  report=$(DRY=$DRY DIR="$dir" python3 -I - <<'PY'
import json, os, glob, shutil
root, dry = os.environ["DIR"], os.environ["DRY"] == "1"
changed = []
def edit(path, fn, label):
    try:
        data = json.load(open(path)) if os.path.exists(path) else {}
    except ValueError:
        print(f"skip {label}: unreadable"); return
    before = json.dumps(data, sort_keys=True)
    fn(data)
    if json.dumps(data, sort_keys=True) == before:
        return
    changed.append(label)
    if dry:
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path) and not os.path.exists(path + ".bak-lowram"):
        shutil.copy2(path, path + ".bak-lowram")
    tmp = path + ".tmp-lowram"
    with open(tmp, "w") as f:
        json.dump(data, f, separators=(",", ":"))
    os.replace(tmp, path)

def prefs(d):
    d.setdefault("browser", {})["custom_chrome_frame"] = True          # no system title bar
    d.setdefault("extensions", {}).setdefault("theme", {})["system_theme"] = 0   # classic, not GTK/Qt
def local_state(d):
    labs = d.setdefault("browser", {}).setdefault("enabled_labs_experiments", [])
    labs[:] = [f for f in labs if not f.startswith("thorium-2024@")] + ["thorium-2024@2"]

profiles = [p for p in glob.glob(os.path.join(root, "Default")) + glob.glob(os.path.join(root, "Profile *"))]
if not profiles:
    profiles = [os.path.join(root, "Default")]          # first run: seed the default profile
for p in profiles:
    edit(os.path.join(p, "Preferences"), prefs, os.path.basename(p))
edit(os.path.join(root, "Local State"), local_state, "Local State")
print("changed " + ", ".join(changed) if changed else "same")
PY
)
  case $report in
    same) same "Thorium: custom frame, classic theme and Thorium 2024 UI already set";;
    changed*) CHANGED=1; if ((DRY)); then printf '  %s[dry-run]%s Thorium settings: %s\n' "$D" "$N" "${report#changed }"
              else ok "Thorium settings set in: ${report#changed }"; fi;;
    *) warn "Thorium settings: $report";;
  esac
}

thorium_install() {
  have thorium-browser && return 0
  if have pacman; then
    local aur=""; have paru && aur=paru; [[ -z $aur ]] && have yay && aur=yay
    if [[ -n $aur ]]; then run user "$aur" -S --needed --noconfirm thorium-browser-bin; return 0; fi
    warn "Thorium is in the AUR (thorium-browser-bin); install an AUR helper (paru/yay) or build it, then re-run"
    return 1
  fi
  local fmt=""; have apt-get && fmt=deb; [[ -z $fmt ]] && { have dnf || have zypper; } && fmt=rpm
  [[ -n $fmt ]] || { warn "install Thorium from https://github.com/Alex313031/thorium/releases, then re-run"; return 1; }
  # Builds are per instruction set; pick the best this CPU runs.
  local isa=SSE3; grep -qw avx /proc/cpuinfo && isa=AVX; grep -qw avx2 /proc/cpuinfo && isa=AVX2
  local url
  url=$(curl -fsSL https://api.github.com/repos/Alex313031/thorium/releases/latest \
        | grep -o "\"browser_download_url\": *\"[^\"]*_${isa}\.${fmt}\"" | sed 's/.*"\(http[^"]*\)"/\1/' | sed -n 1p || true)
  [[ -n $url ]] || { warn "no Thorium $isa .$fmt in the latest release — install it by hand, then re-run"; return 1; }
  if ((DRY)); then run root "install $url"; return 0; fi
  local pkg; pkg=$(mktemp -d)/thorium.$fmt
  curl -fL --progress-bar -o "$pkg" "$url" || { warn "download failed: $url"; return 1; }
  case $fmt in
    deb) run root apt-get install -y "$pkg";;
    rpm) if have dnf; then run root dnf install -y "$pkg"; else run root zypper --non-interactive install "$pkg"; fi;;
  esac
  CHANGED=1
}

thorium_default_browser() {
  local id=$1 current
  current=$(xdg-settings get default-web-browser 2>/dev/null || true)
  if [[ $current == "$id" ]]; then same "default browser is already $id"; return 0; fi
  run user xdg-settings set default-web-browser "$id" 2>/dev/null || true
  local mime
  for mime in text/html application/xhtml+xml x-scheme-handler/http x-scheme-handler/https x-scheme-handler/about x-scheme-handler/unknown; do
    run user xdg-mime default "$id" "$mime" 2>/dev/null || true  # xdg-utils on KDE complains about qtpaths; harmless
  done
  # Plasma also keeps its own "web browser" setting.
  have kwriteconfig6 && run user kwriteconfig6 --file kdeglobals --group General --key BrowserApplication "$id"
  CHANGED=1; ((DRY)) || ok "default browser: $id (was ${current:-unset})"
}

# Thorium Lite: a second launcher next to the normal one. Same profile, but tabs share renderer
# processes instead of one each and every renderer's JS heap is capped. The flags only apply when
# Thorium isn't already running (otherwise the window opens in the running browser).
thorium_lite() {
  local real; real=$(command -v thorium-browser)
  local wrapper="$HOME/.local/bin/thorium-lite"
  write_file user "$wrapper" "#!/bin/sh
# Thorium Lite: tabs share up to $THORIUM_RENDERER_LIMIT renderer processes; each renderer's JS heap is capped.
# Flags only take effect when Thorium is not already running.
exec $real \\
  --renderer-process-limit=$THORIUM_RENDERER_LIMIT \\
  --js-flags=\"--max-old-space-size=256\" \\
  --disable-smooth-scrolling \\
  \"\$@\""
  run user chmod +x "$wrapper"

  if [[ -f $THORIUM_DESKTOP_SRC ]]; then
    # A copy of Thorium's entry: every Exec launches the wrapper, only the entry's own name says Lite.
    local entry
    entry=$(W="$wrapper" awk '
      /^\[/ { main = ($0 == "[Desktop Entry]") }
      /^Exec=/ { sub(/^Exec=[^ ]+/, "Exec=" ENVIRON["W"]) }
      main && /^Name=/ { $0 = $0 " (Lite)" }
      { print }' "$THORIUM_DESKTOP_SRC")
    write_file user "$HOME/.local/share/applications/thorium-lite.desktop" "$entry"
  else
    warn "no $THORIUM_DESKTOP_SRC — start $wrapper directly"
  fi
}

c_thorium() {
  thorium_install || return 0
  ((DRY)) && ! have thorium-browser && { same "(dry run: the rest needs Thorium installed)"; return 0; }
  ((THORIUM_LITE)) && thorium_lite

  local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/thorium"
  if pgrep -u "$(id -u)" -x thorium >/dev/null 2>&1 || pgrep -u "$(id -u)" -f '/thorium-browser/thorium( |$)' >/dev/null 2>&1; then
    warn "Thorium is running — close it and re-run to apply the window-frame/UI settings (it rewrites them on exit)"
  else
    thorium_prefs "$cfg"
  fi

  if [[ $THORIUM_DEFAULT_BROWSER == 1 ]]; then
    # The packages' entry is thorium-browser.desktop; fall back to any entry that launches Thorium.
    local id=thorium-browser.desktop other
    if [[ ! -f /usr/share/applications/$id && ! -f $HOME/.local/share/applications/$id ]]; then
      other=$(grep -ls 'Exec=.*thorium-browser' /usr/share/applications/*.desktop 2>/dev/null | sed -n 1p || true)
      [[ -n $other ]] && id=$(basename "$other")
    fi
    thorium_default_browser "$id"
  fi
}


# ───────────── JetBrains IDEs ─────────────

# Plugin IDs from list files (comments and blank lines dropped).
plugin_ids() { sed -e 's/#.*//' -e 's/[[:space:]\r]//g' "$@" | grep -v '^$' || true; }

# merge_plugins <disabled_plugins.txt> <list files...>: add the listed IDs, keep whatever is there.
merge_plugins() {
  local target=$1; shift
  local merged; merged=$( { cat "$target" 2>/dev/null || true; plugin_ids "$@"; } | grep -v '^$' | sort -u)
  local before; before=$(sort -u "$target" 2>/dev/null | grep -v '^$' || true)
  if [[ "$merged" == "$before" ]]; then same "$target: plugins already disabled"; return 0; fi
  write_file user "$target" "$merged"
}

# build_vmoptions <ide's own .vmoptions> <overrides file>: the IDE defaults with our overrides applied.
build_vmoptions() {
  awk '
    function key(l) {
      if (l ~ /^-Xm[sx]/) return substr(l, 1, 4)
      if (l ~ /^-XX:[+-]/) return "-XX:" substr(l, 6)
      i = index(l, "="); return i ? substr(l, 1, i) : l
    }
    FNR == NR {                                   # overrides
      if ($0 ~ /^#/ || $0 == "") next
      if ($0 ~ /^!/) { drop[++nd] = substr($0, 2); next }
      over[key($0)] = $0; order[++no] = key($0); next
    }
    /^#/ || $0 == "" { next }                     # IDE defaults
    { for (d = 1; d <= nd; d++) if (index($0, drop[d]) == 1) next }
    { k = key($0); if (k in over) { if (!(k in done)) { print over[k]; done[k] = 1 } ; next } print }
    END { for (o = 1; o <= no; o++) if (!(order[o] in done)) print over[order[o]] }
  ' "$2" "$1"
}

# find_ide_home <launcher> <dir globs...>: the first install directory that has bin/<launcher>.
find_ide_home() {
  local launcher=$1; shift
  local pattern d
  for pattern in "$@"; do
    for d in $pattern; do
      [[ -x "$d/bin/$launcher" || -x "$d/bin/$launcher.sh" ]] && { echo "$d"; return 0; }
    done
  done
  return 1
}

# merge_ignored <profile dir>: add ignored-folders.txt to the profile's global "Ignored Files and
# Folders" list (options/filetypes.xml), keeping the IDE's own entries.
merge_ignored() {
  local file="$1/options/filetypes.xml" report
  report=$(DRY=$DRY FILE="$file" LIST="$HERE/jetbrains/ignored-folders.txt" python3 -I - <<'PY'
import os, re, shutil
path, dry = os.environ["FILE"], os.environ["DRY"] == "1"
wanted = [l.strip() for l in open(os.environ["LIST"]) if l.strip() and not l.lstrip().startswith("#")]
# The platform's default list, used when the profile has never customised it.
default = "*.pyc;*.pyo;*.rbc;*.yarb;*~;.DS_Store;.git;.hg;.svn;CVS;__pycache__;_svn;vssver.scc;vssver2.scc;"
text = open(path).read() if os.path.exists(path) else ""
m = re.search(r'<ignoreFiles list="([^"]*)"', text)
current = m.group(1) if m else default
entries = [e for e in current.split(";") if e]
missing = [w for w in wanted if w not in entries]
if not missing:
    print("same"); raise SystemExit
new_list = ";".join(entries + missing) + ";"
if m:
    text = text[:m.start(1)] + new_list + text[m.end(1):]
elif "<component name=\"FileTypeManager\"" in text:
    text = re.sub(r'(<component name="FileTypeManager"[^>]*>)', r'\1\n    <ignoreFiles list="' + new_list + '" />', text, count=1)
else:
    text = ('<application>\n  <component name="FileTypeManager" version="18">\n'
            f'    <ignoreFiles list="{new_list}" />\n  </component>\n</application>\n')
if not dry:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path) and not os.path.exists(path + ".bak-lowram"):
        shutil.copy2(path, path + ".bak-lowram")
    with open(path, "w") as f:
        f.write(text)
print("added " + " ".join(missing))
PY
)
  case $report in
    same) same "$file: folders already ignored";;
    added*) CHANGED=1; if ((DRY)); then printf '  %s[dry-run]%s %s: ignore %s\n' "$D" "$N" "$file" "${report#added }"
            else ok "$file: now ignores ${report#added }"; fi;;
    *) warn "could not update $file: $report";;
  esac
}

# merge_inspections <profile dir> <rust 0|1>: switch off inspections-off.txt in the template for new
# projects (options/project.default.xml); for RustRover also turn off cargo check on the fly.
# Text-level edits on purpose: the file carries IDE-written CDATA a parser round-trip would mangle.
merge_inspections() {
  local file="$1/options/project.default.xml" report
  report=$(DRY=$DRY FILE="$file" LIST="$HERE/jetbrains/inspections-off.txt" RUST="$2" python3 -I - <<'PY'
import os, re, shutil
path, dry, rust = os.environ["FILE"], os.environ["DRY"] == "1", os.environ["RUST"] == "1"
wanted = []
for line in open(os.environ["LIST"]):
    line = line.strip()
    if line and not line.startswith("#"):
        cls, _, level = line.partition(" ")
        wanted.append((cls, level.strip() or "WARNING"))
text = open(path).read() if os.path.exists(path) else ""
original = text
if "<defaultProject>" not in text:
    text = ('<application>\n  <component name="ProjectManager">\n    <defaultProject>\n'
            '    </defaultProject>\n  </component>\n</application>\n')
ind = "      "
added = []
if '<component name="InspectionProjectProfileManager">' not in text:
    block = (f'{ind}<component name="InspectionProjectProfileManager">\n{ind}  <profile version="1.0">\n'
             f'{ind}    <option name="myName" value="Project Default" />\n{ind}  </profile>\n{ind}</component>\n')
    text = text.replace("    </defaultProject>", block + "    </defaultProject>", 1)
start = text.index('<component name="InspectionProjectProfileManager">')
end = text.index("</profile>", start)
section = text[start:end]
lines = ""
for cls, level in wanted:
    if f'class="{cls}"' in section:
        # present: make sure it's off
        section = re.sub(r'(<inspection_tool class="' + re.escape(cls) + r'"[^>]*?)enabled="true"', r'\1enabled="false"', section)
        continue
    lines += (f'{ind}    <inspection_tool class="{cls}" enabled="false" level="{level}" '
              f'enabled_by_default="false" />\n')
    added.append(cls)
text = text[:start] + section + text[end:]          # end is the pre-edit position of </profile>
end = text.index("</profile>", start)
indent_end = text.rfind("\n", 0, end) + 1
text = text[:indent_end] + lines + text[indent_end:]
if rust:
    if '<component name="RsExternalLinterProjectSettings">' not in text:
        text = text.replace("    </defaultProject>",
            f'{ind}<component name="RsExternalLinterProjectSettings">\n{ind}  <option name="runOnTheFly" value="false" />\n'
            f'{ind}</component>\n    </defaultProject>', 1)
        added.append("cargo-check-on-the-fly")
    else:
        new = re.sub(r'(<component name="RsExternalLinterProjectSettings">.*?<option name="runOnTheFly" value=")true(")',
                     r'\1false\2', text, count=1, flags=re.S)
        if new != text:
            text = new; added.append("cargo-check-on-the-fly")
if text == original:
    print("same"); raise SystemExit
if not dry:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path) and not os.path.exists(path + ".bak-lowram"):
        shutil.copy2(path, path + ".bak-lowram")
    with open(path, "w") as f:
        f.write(text)
print(f"changed {len(added)} " + " ".join(added))
PY
)
  case $report in
    same) same "$file: inspections already off for new projects";;
    changed*) CHANGED=1; local n=${report#changed }; n=${n%% *}
      if ((DRY)); then printf '  %s[dry-run]%s %s: switch off %s inspections for new projects\n' "$D" "$N" "$file" "$n"
      else ok "$file: $n inspections off for new projects"; fi;;
    *) warn "could not update $file: $report";;
  esac
}

# jetbrains_product <slug> <config prefix> <launcher> <env prefix> <plugin list> <WM class> <install globs...>
jetbrains_product() {
  local slug=$1 prefix=$2 launcher=$3 envp=$4 list=$5 wmclass=$6; shift 6
  local rust=0; [[ $slug == rustrover ]] && rust=1
  local -a globs=()
  local r; IFS=: read -r -a extra <<<"$JETBRAINS_ROOTS"
  for r in "${extra[@]}"; do [[ -n $r ]] && globs+=("$r"); done
  globs+=("$@")
  local home; home=$(find_ide_home "$launcher" "${globs[@]}") || return 0

  # The newest normal (non-Lite) profile of this product.
  local cfg
  cfg=$(find "$HOME/.config/JetBrains" -maxdepth 1 -type d -name "${prefix}[0-9]*" ! -name '*-lite' 2>/dev/null | sort -V | tail -1)
  if [[ -z $cfg ]]; then warn "$slug is installed in $home but has no profile yet — start it once, then re-run"; return 0; fi
  ok "$slug: $home, profile $(basename "$cfg")"

  have python3 || { warn "python3 is needed for the JetBrains component — skipped"; return 0; }
  local running=0
  if pgrep -u "$(id -u)" -f "$home/" >/dev/null 2>&1; then
    running=1; warn "$slug is running — close it and re-run to change plugin lists (it rewrites them on exit)"
  fi

  if ((!running)) && [[ $JETBRAINS_TRIM_MAIN == 1 ]]; then
    merge_plugins "$cfg/disabled_plugins.txt" "$HERE/jetbrains/$list"
    merge_ignored "$cfg"
    merge_inspections "$cfg" "$rust"
  fi

  # Lite profile: a copy of the settings (license included) that then lives on its own.
  local lite_cfg="$cfg-lite" base; base=$(basename "$cfg")
  if [[ ! -d $lite_cfg ]]; then
    run user cp -a "$cfg" "$lite_cfg"; ok "created Lite profile $(basename "$lite_cfg") from $base"; CHANGED=1
  fi
  if ((!running)); then
    merge_plugins "$lite_cfg/disabled_plugins.txt" "$HERE/jetbrains/$list" "$HERE/jetbrains/lite-extra.disabled-plugins.txt"
    merge_ignored "$lite_cfg"
    merge_inspections "$lite_cfg" "$rust"
  fi

  local dir="$HOME/.config/JetBrains/lite"
  # shellcheck disable=SC2016  # ${user.home} is expanded by the IDE, not the shell
  write_file user "$dir/$slug-lite.properties" "$(printf '%s\n' \
    'idea.config.path=${user.home}/.config/JetBrains/'"$base"'-lite' \
    'idea.system.path=${user.home}/.cache/JetBrains/'"$base"'-lite' \
    'idea.plugins.path=${user.home}/.local/share/JetBrains/'"$base"'-lite' \
    'idea.log.path=${user.home}/.cache/JetBrains/'"$base"'-lite/log' \
    'shared.indexes.download=false' \
    'ide.show.tips.on.startup.default.value=false')"

  local vmfile; vmfile=$(find "$home/bin" -maxdepth 1 -name '*64.vmoptions' -print -quit)
  if [[ -n $vmfile ]]; then
    write_file user "$dir/$slug-lite.vmoptions" "$(build_vmoptions "$vmfile" "$HERE/jetbrains/lite.vmoptions-overrides")"
  else
    warn "no *64.vmoptions in $home/bin — Lite uses the IDE's default memory settings"
  fi

  local exe="$home/bin/$launcher"; [[ -x $exe ]] || exe="$exe.sh"
  write_file user "$HOME/.local/bin/$slug-lite" "#!/bin/sh
# $slug Lite: its own profile without AI completion, Grazie and MCP, 1 GB heap.
export ${envp}_PROPERTIES=\"$dir/$slug-lite.properties\"
export ${envp}_VM_OPTIONS=\"$dir/$slug-lite.vmoptions\"
# glibc keeps up to 8 malloc arenas per core; with ~180 JVM threads that is 100-300 MB of slack.
export MALLOC_ARENA_MAX=2
exec $exe \"\$@\""
  run user chmod +x "$HOME/.local/bin/$slug-lite"

  local icon="$home/bin/$launcher.svg"; [[ -f $icon ]] || icon="$home/bin/$launcher.png"
  local title; title=$(sed -n '/"name"/{s/.*"name": *"\([^"]*\)".*/\1/p;q;}' "$home/product-info.json" 2>/dev/null || true)
  write_file user "$HOME/.local/share/applications/jetbrains-$slug-lite.desktop" "[Desktop Entry]
Type=Application
Name=${title:-$slug} Lite
Comment=$slug without AI completion, grammar checks and MCP; separate profile, 1 GB heap
Exec=$HOME/.local/bin/$slug-lite %f
Icon=$icon
Terminal=false
StartupWMClass=$wmclass
Categories=Development;IDE;"
}

c_jetbrains() {
  local before=$CHANGED found=0 tb="$HOME/.local/share/JetBrains/Toolbox/apps"
  jetbrains_product idea IntelliJIdea idea IDEA idea.disabled-plugins.txt jetbrains-idea \
    /opt/intellij-idea-ultimate-edition /opt/idea-IU-* /opt/intellij-idea-ultimate "$tb/intellij-idea-ultimate*" \
    "$tb/IDEA-U/ch-0/*" /snap/intellij-idea-ultimate/current /usr/share/idea
  jetbrains_product idea-ce IdeaIC idea IDEA idea.disabled-plugins.txt jetbrains-idea-ce \
    /opt/intellij-idea-community-edition /opt/idea-IC-* "$tb/intellij-idea-community*" "$tb/IDEA-C/ch-0/*" \
    /snap/intellij-idea-community/current /usr/share/idea-ce
  jetbrains_product rustrover RustRover rustrover RUSTROVER rustrover.disabled-plugins.txt jetbrains-rustrover \
    /opt/rustrover /opt/RustRover-* "$tb/rustrover*" "$tb/RustRover/ch-0/*" /snap/rustrover/current
  for _ in "$HOME"/.local/bin/{idea,idea-ce,rustrover}-lite; do [[ -e $_ ]] && found=1; done
  ((found || CHANGED != before)) || same "no IntelliJ IDEA or RustRover install found"
}

c_mcp-lazy() {
  if have mcp-lazy; then same "mcp-lazy already installed ($(command -v mcp-lazy))"
  elif have cargo; then run user cargo install --locked --git "$MCP_LAZY_REPO" mcp-lazy; CHANGED=1
  else warn "cargo not found — install Rust (https://rustup.rs) and re-run"; return 0; fi
  local bin; bin=$(command -v mcp-lazy 2>/dev/null || echo "$HOME/.cargo/bin/mcp-lazy")

  local config="$HOME/.claude.json"
  [[ -f $config ]] || { same "no ~/.claude.json — nothing to wrap"; return 0; }
  have python3 || { warn "python3 needed to edit ~/.claude.json — skipped"; return 0; }
  if pgrep -x claude >/dev/null 2>&1; then
    warn "Claude Code is running; it rewrites ~/.claude.json — changes apply to new sessions"
  fi
  # Wrap user-scope stdio servers that aren't wrapped yet; prints one line per server.
  local report
  report=$(DRY=$DRY BIN="$bin" FLAGS="$MCP_LAZY_FLAGS" CONFIG="$config" python3 -I - <<'PY'
import json, os, shlex, shutil
path, binary, flags, dry = os.environ["CONFIG"], os.environ["BIN"], shlex.split(os.environ["FLAGS"]), os.environ["DRY"] == "1"
cfg = json.load(open(path))
changed = False
for name, srv in (cfg.get("mcpServers") or {}).items():
    if srv.get("type", "stdio") != "stdio" or "command" not in srv:
        print(f"same {name}: not a stdio server"); continue
    if os.path.basename(srv["command"]) == "mcp-lazy":
        print(f"same {name}: already wrapped"); continue
    srv["args"] = ["--name", name, *flags, "--", srv["command"], *srv.get("args", [])]
    srv["command"] = binary
    changed = True
    print(f"ok {name}: wrapped")
if changed and not dry:
    if not os.path.exists(path + ".bak-lowram"):
        shutil.copy2(path, path + ".bak-lowram")
    tmp = path + ".tmp-lowram"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2)
    os.replace(tmp, path)
    print("changed")
PY
)
  local line
  while IFS= read -r line; do
    case $line in
      ok\ *) ok "${line#ok }";; same\ *) same "${line#same }";; changed) CHANGED=1;;
    esac
  done <<<"$report"
}

# ───────────────────────────── main ─────────────────────────────

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  local only="" skip=""
  while (($#)); do
    case $1 in
      --dry-run|-n) DRY=1;;
      --only) only=${2:?}; shift;;
      --only=*) only=${1#*=};;
      --skip) skip=${2:?}; shift;;
      --skip=*) skip=${1#*=};;
      --list) for c in "${COMPONENTS[@]}"; do printf '  %-9s %s\n' "$c" "${DESCRIPTION[$c]}"; done; exit 0;;
      -h|--help) usage; exit 0;;
      *) die "unknown option: $1 (see --help)";;
    esac
    shift
  done
  [[ $EUID -eq 0 ]] && die "run as your normal user; root parts use sudo"
  [[ $(uname -s) == Linux ]] || die "Linux only"

  local selected=() c
  for c in "${COMPONENTS[@]}"; do
    [[ -n $only && ",$only," != *",$c,"* ]] && continue
    [[ ",$skip," == *",$c,"* ]] && continue
    selected+=("$c")
  done
  [[ -n $only ]] && for c in ${only//,/ }; do [[ -n ${DESCRIPTION[$c]:-} ]] || die "unknown component: $c"; done
  ((${#selected[@]})) || die "nothing selected"

  ((DRY)) && printf '%sDry run — nothing will be changed.%s\n' "$B" "$N"
  local needs_root=0
  for c in "${selected[@]}"; do [[ " ${ROOT_COMPONENTS[*]} " == *" $c "* ]] && needs_root=1; done
  if ((needs_root && !DRY)); then sudo -v || die "sudo is required"; fi

  for c in "${selected[@]}"; do
    section "$c — ${DESCRIPTION[$c]}"
    "c_$c"
  done
  apply_cmdline

  section "done"
  if ((CHANGED)); then
    ((DRY)) && echo "  Run without --dry-run to apply." \
            || echo "  Applied. Kernel parameters take effect after a reboot; the rest is live already."
  else
    echo "  Everything was already in place."
  fi
}

# Allow `source install.sh` from tests without running main.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
