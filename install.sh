#!/usr/bin/env bash
# Low-RAM desktop tuning — see README.md for what each component does and why.
#
#   ./install.sh                     apply every component
#   ./install.sh --dry-run           print what would change, change nothing
#   ./install.sh --only zswap,thp    apply only these components
#   ./install.sh --skip chrome       apply all but these
#   ./install.sh --list              list components
#
# Run as your normal user: system parts use sudo, user parts (KDE, Chrome, MCP) need your $HOME.
# Every component is idempotent; every file it rewrites is backed up once as <file>.bak-lowram.
set -euo pipefail

COMPONENTS=(zswap thp mglru earlyoom baloo kwin chrome jetbrains mcp-lazy)
ROOT_COMPONENTS=(zswap thp mglru earlyoom)
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
declare -A DESCRIPTION=(
  [zswap]="zswap (zstd, 25% pool, shrinker) in front of disk swap; zram off; swappiness 100"
  [thp]="transparent huge pages: madvise instead of always"
  [mglru]="MGLRU thrashing protection: min_ttl_ms=1000"
  [earlyoom]="earlyoom with prefer (browsers, JVM, compilers) / avoid (desktop, audio) rules"
  [baloo]="KDE: disable the Baloo file indexer"
  [kwin]="KDE: disable heavy KWin effects"
  [chrome]="Chrome/Chromium launcher with a renderer-process cap"
  [jetbrains]="IntelliJ IDEA / RustRover: trim plugins; add Lite profiles (no AI completion, Grazie, MCP; 1.5 GB heap)"
  [mcp-lazy]="AI agents: build mcp-lazy and wrap user-scope stdio MCP servers in ~/.claude.json"
)

ZSWAP_POOL_PERCENT=${ZSWAP_POOL_PERCENT:-25}
SWAPPINESS=${SWAPPINESS:-100}
MGLRU_MIN_TTL_MS=${MGLRU_MIN_TTL_MS:-1000}
CHROME_RENDERER_LIMIT=${CHROME_RENDERER_LIMIT:-6}
MCP_LAZY_FLAGS=${MCP_LAZY_FLAGS:---gate --per-cwd}
MCP_LAZY_REPO=${MCP_LAZY_REPO:-https://github.com/Migiht/mcp-lazy}
EARLYOOM_ARGS_DEFAULT="-m 5 -s 10 -r 3600 --prefer '(^|/)(firefox|chrome|chromium|electron|java|node|cc1plus|rustc|ld)\$' --avoid '(^|/)(init|systemd|systemd-.*|kwin_wayland|plasmashell|Xwayland|sddm|sddm-helper|pipewire|wireplumber|sshd|dbus-.*)\$'"
EARLYOOM_ARGS=${EARLYOOM_ARGS:-$EARLYOOM_ARGS_DEFAULT}
KWIN_EFFECTS=(blur fadingpopups frozenapp fullscreen maximize scale screenedge slide slidingnotifications slidingpopups squash windowaperture)
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

c_chrome() {
  local bin="" id=""
  for bin in google-chrome-stable chromium thorium-browser brave-browser; do
    if have "$bin"; then id=$bin; break; fi
  done
  [[ -n $id ]] || { same "no Chrome/Chromium found — skipped"; return 0; }
  local existing
  existing=$(grep -l -- '--renderer-process-limit' "$HOME"/.local/bin/*-lite 2>/dev/null | head -1 || true)
  if [[ -n $existing && $existing != "$HOME/.local/bin/$id-lite" ]]; then
    same "a renderer-capped launcher already exists ($existing) — skipped"; return 0
  fi
  local real; real=$(command -v "$id")
  local wrapper="$HOME/.local/bin/$id-lite"
  write_file user "$wrapper" "#!/bin/sh
# $id with a renderer-process cap: tabs share renderer processes instead of one each.
# Flags only take effect when the browser is not already running.
exec $real \\
  --renderer-process-limit=$CHROME_RENDERER_LIMIT \\
  --js-flags=\"--max-old-space-size=256\" \\
  --disable-smooth-scrolling \\
  \"\$@\""
  run user chmod +x "$wrapper"

  # A desktop entry next to the system one, launching the wrapper.
  local src=""
  for src in /usr/share/applications/{google-chrome,chromium,org.chromium.Chromium,thorium-browser,brave-browser}.desktop; do
    [[ -f $src ]] && grep -q "$(basename "$real")\|$id" "$src" && break; src=""
  done
  if [[ -n $src ]]; then
    local entry
    # Every Exec launches the wrapper; only the entry's own name gets the "(Lite)" suffix.
    entry=$(W="$wrapper" awk '
      /^\[/ { main = ($0 == "[Desktop Entry]") }
      /^Exec=/ { sub(/^Exec=[^ ]+/, "Exec=" ENVIRON["W"]) }
      main && /^Name=/ { $0 = $0 " (Lite)" }
      { print }' "$src")
    write_file user "$HOME/.local/share/applications/$id-lite.desktop" "$entry"
  else
    warn "no system desktop file for $id found; start $wrapper directly"
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

# jetbrains_product <slug> <config prefix> <launcher> <env prefix> <plugin list> <WM class> <install globs...>
jetbrains_product() {
  local slug=$1 prefix=$2 launcher=$3 envp=$4 list=$5 wmclass=$6; shift 6
  local -a globs=()
  local r; IFS=: read -r -a extra <<<"$JETBRAINS_ROOTS"
  for r in "${extra[@]}"; do [[ -n $r ]] && globs+=("$r"); done
  globs+=("$@")
  local home; home=$(find_ide_home "$launcher" "${globs[@]}") || return 0

  # The newest normal (non-Lite) profile of this product.
  local cfg
  cfg=$(find "$HOME/.config/JetBrains" -maxdepth 1 -type d -name "$prefix[0-9]*" ! -name '*-lite' 2>/dev/null | sort -V | tail -1)
  if [[ -z $cfg ]]; then warn "$slug is installed in $home but has no profile yet — start it once, then re-run"; return 0; fi
  ok "$slug: $home, profile $(basename "$cfg")"

  local running=0
  if pgrep -u "$(id -u)" -f "$home/" >/dev/null 2>&1; then
    running=1; warn "$slug is running — close it and re-run to change plugin lists (it rewrites them on exit)"
  fi

  if ((!running)) && [[ $JETBRAINS_TRIM_MAIN == 1 ]]; then
    merge_plugins "$cfg/disabled_plugins.txt" "$HERE/jetbrains/$list"
  fi

  # Lite profile: a copy of the settings (license included) that then lives on its own.
  local lite_cfg="$cfg-lite" base; base=$(basename "$cfg")
  if [[ ! -d $lite_cfg ]]; then
    run user cp -a "$cfg" "$lite_cfg"; ok "created Lite profile $(basename "$lite_cfg") from $base"; CHANGED=1
  fi
  ((running)) || merge_plugins "$lite_cfg/disabled_plugins.txt" "$HERE/jetbrains/$list" "$HERE/jetbrains/lite-extra.disabled-plugins.txt"

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
# $slug Lite: its own profile without AI completion, Grazie and MCP, 1.5 GB heap.
export ${envp}_PROPERTIES=\"$dir/$slug-lite.properties\"
export ${envp}_VM_OPTIONS=\"$dir/$slug-lite.vmoptions\"
exec $exe \"\$@\""
  run user chmod +x "$HOME/.local/bin/$slug-lite"

  local icon="$home/bin/$launcher.svg"; [[ -f $icon ]] || icon="$home/bin/$launcher.png"
  local title; title=$(sed -n '/"name"/{s/.*"name": *"\([^"]*\)".*/\1/p;q;}' "$home/product-info.json" 2>/dev/null || true)
  write_file user "$HOME/.local/share/applications/jetbrains-$slug-lite.desktop" "[Desktop Entry]
Type=Application
Name=${title:-$slug} Lite
Comment=$slug without AI completion, grammar checks and MCP; separate profile, 1.5 GB heap
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
