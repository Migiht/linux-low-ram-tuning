#!/usr/bin/env bash
# Tests for install.sh that need no root and change nothing outside a temp dir.
#   tests/run.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=install.sh
source ./install.sh

pass=0 fail=0
check() { # check <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else fail=$((fail + 1)); printf '  FAIL %s\n       expected: %q\n       actual:   %q\n' "$1" "$2" "$3"; fi
}

echo "set_params"
check "appends a missing key" \
  "root=/dev/sda1 rw zswap.enabled=1" "$(set_params 'root=/dev/sda1 rw' zswap.enabled=1)"
check "replaces a key in place, keeping order" \
  "root=X zswap.enabled=1 rw quiet" "$(set_params 'root=X zswap.enabled=0 rw quiet' zswap.enabled=1)"
check "replaces a bare flag" \
  "a transparent_hugepage=madvise b" "$(set_params 'a transparent_hugepage b' transparent_hugepage=madvise)"
check "drops duplicate occurrences" \
  "zswap.enabled=1 rw" "$(set_params 'zswap.enabled=0 rw zswap.enabled=0' zswap.enabled=1)"
check "does not touch keys sharing a prefix" \
  "zswap.enabled_x=0 zswap.enabled=1" "$(set_params 'zswap.enabled_x=0' zswap.enabled=1)"
check "is idempotent" \
  "rw zswap.enabled=1 zswap.compressor=zstd" \
  "$(set_params "$(set_params 'rw' zswap.enabled=1 zswap.compressor=zstd)" zswap.enabled=1 zswap.compressor=zstd)"
check "handles several keys" \
  "root=X zswap.enabled=1 transparent_hugepage=madvise" \
  "$(set_params 'root=X zswap.enabled=0' zswap.enabled=1 transparent_hugepage=madvise)"
check "keeps values with '=' inside" \
  "root=PARTUUID=abc-1 rw" "$(set_params 'root=PARTUUID=abc-1 rw' rw)"
check "works on an empty line" "quiet" "$(set_params '' quiet)"

echo "mcp-lazy: wrapping ~/.claude.json"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
printf '#!/bin/sh\n' >"$tmp/bin/mcp-lazy"; chmod +x "$tmp/bin/mcp-lazy"
cat >"$tmp/.claude.json" <<'EOF'
{
  "numStartups": 3,
  "mcpServers": {
    "plain":   { "type": "stdio", "command": "/opt/srv", "args": ["--x"], "env": { "K": "V" } },
    "notype":  { "command": "node", "args": ["s.mjs"] },
    "remote":  { "type": "http", "url": "https://example.com/mcp" },
    "wrapped": { "type": "stdio", "command": "/usr/bin/mcp-lazy", "args": ["--name", "wrapped", "--", "srv"] }
  },
  "projects": { "/p": { "mcpServers": { "local": { "command": "x" } } } }
}
EOF
out=$(HOME="$tmp" PATH="$tmp/bin:$PATH" ./install.sh --only mcp-lazy 2>&1)
json() { python3 -I -c "import json,sys; d=json.load(open('$tmp/.claude.json')); print(json.dumps(eval(sys.argv[1])))" "$1"; }
check "wraps a stdio server, keeping args and env" \
  '{"type": "stdio", "command": "'"$tmp"'/bin/mcp-lazy", "args": ["--name", "plain", "--gate", "--per-cwd", "--", "/opt/srv", "--x"], "env": {"K": "V"}}' \
  "$(json 'd["mcpServers"]["plain"]')"
check "wraps a server without an explicit type" \
  '["--name", "notype", "--gate", "--per-cwd", "--", "node", "s.mjs"]' "$(json 'd["mcpServers"]["notype"]["args"]')"
check "leaves remote servers alone" '{"type": "http", "url": "https://example.com/mcp"}' "$(json 'd["mcpServers"]["remote"]')"
check "does not double-wrap" '["--name", "wrapped", "--", "srv"]' "$(json 'd["mcpServers"]["wrapped"]["args"]')"
check "leaves project-scope servers alone" '{"command": "x"}' "$(json 'd["projects"]["/p"]["mcpServers"]["local"]')"
check "keeps unrelated settings" '3' "$(json 'd["numStartups"]')"
check "backs up the original once" '"/opt/srv"' \
  "$(python3 -I -c "import json; print(json.dumps(json.load(open('$tmp/.claude.json.bak-lowram'))['mcpServers']['plain']['command']))")"
check "reports what it wrapped" "yes" "$(grep -q 'plain: wrapped' <<<"$out" && echo yes || echo "no: $out")"

before=$(cat "$tmp/.claude.json")
out2=$(HOME="$tmp" PATH="$tmp/bin:$PATH" ./install.sh --only mcp-lazy 2>&1)
check "second run changes nothing" "$before" "$(cat "$tmp/.claude.json")"
check "second run says so" "yes" "$(grep -q 'already in place' <<<"$out2" && echo yes || echo "no: $out2")"

echo "dry run"
cp "$tmp/.claude.json.bak-lowram" "$tmp/fresh.json"; mv "$tmp/fresh.json" "$tmp/.claude.json"; rm "$tmp/.claude.json.bak-lowram"
before=$(cat "$tmp/.claude.json")
HOME="$tmp" PATH="$tmp/bin:$PATH" ./install.sh --dry-run --only mcp-lazy >/dev/null 2>&1
check "--dry-run leaves ~/.claude.json untouched" "$before" "$(cat "$tmp/.claude.json")"
check "--dry-run makes no backup" "no" "$([[ -e $tmp/.claude.json.bak-lowram ]] && echo yes || echo no)"

echo "chrome wrapper"
mkdir -p "$tmp/fakebin"
printf '#!/bin/sh\necho "args: $*"\n' >"$tmp/fakebin/google-chrome-stable"; chmod +x "$tmp/fakebin/google-chrome-stable"
HOME="$tmp" PATH="$tmp/fakebin:/usr/bin:/bin" ./install.sh --only chrome >/dev/null 2>&1
check "wrapper passes the renderer cap and user args" \
  "args: --renderer-process-limit=6 --js-flags=--max-old-space-size=256 --disable-smooth-scrolling https://x" \
  "$("$tmp/.local/bin/google-chrome-stable-lite" https://x)"

echo "jetbrains: vmoptions"
cat >"$tmp/base.vmoptions" <<'EOF'
# defaults
-Xms128m
-Xmx3072m
-XX:ReservedCodeCacheSize=512m
-XX:+UseCompactObjectHeaders
-Dllm.show.ai.promotion.window.on.start=true
-Denable.non.commercial.ai.license=true
-ea
EOF
printf '%s\n' '# o' '-Xmx2048m' '-XX:ReservedCodeCacheSize=256m' '-XX:-UseCompactObjectHeaders' \
  '-Dllm.show.ai.promotion.window.on.start=false' '!-Denable.non.commercial' '-XX:SoftRefLRUPolicyMSPerMB=50' >"$tmp/over"
check "overrides replace in place, drop, flip flags and append" \
  "$(printf '%s\n' -Xms128m -Xmx2048m -XX:ReservedCodeCacheSize=256m -XX:-UseCompactObjectHeaders \
     -Dllm.show.ai.promotion.window.on.start=false -ea -XX:SoftRefLRUPolicyMSPerMB=50)" \
  "$(build_vmoptions "$tmp/base.vmoptions" "$tmp/over")"

echo "jetbrains: profiles"
jb="$tmp/jb"; ide="$jb/opt/rustrover"
mkdir -p "$ide/bin" "$jb/.config/JetBrains/RustRover2026.2"
printf '#!/bin/sh\necho "props=$RUSTROVER_PROPERTIES vm=$RUSTROVER_VM_OPTIONS args=$*"\n' >"$ide/bin/rustrover"; chmod +x "$ide/bin/rustrover"
cp "$tmp/base.vmoptions" "$ide/bin/rustrover64.vmoptions"
echo '{ "name": "RustRover", "version": "2026.2" }' >"$ide/product-info.json"
printf 'already.off\n' >"$jb/.config/JetBrains/RustRover2026.2/disabled_plugins.txt"
echo "license" >"$jb/.config/JetBrains/RustRover2026.2/rustrover.key"
HOME="$jb" JETBRAINS_ROOTS="$ide" ./install.sh --only jetbrains >"$tmp/jb.out" 2>&1
main="$jb/.config/JetBrains/RustRover2026.2" lite="$jb/.config/JetBrains/RustRover2026.2-lite"
check "keeps plugins the user already disabled" "yes" "$(grep -qx already.off "$main/disabled_plugins.txt" && echo yes)"
check "trims the main profile" "yes" "$(grep -qx com.intellij.lang.qml "$main/disabled_plugins.txt" && echo yes)"
check "main profile keeps AI completion" "no" "$(grep -qx org.jetbrains.completion.full.line "$main/disabled_plugins.txt" && echo yes || echo no)"
check "Lite profile is a copy (license included)" "license" "$(cat "$lite/rustrover.key" 2>/dev/null)"
check "Lite disables AI completion, Grazie and MCP" "3" \
  "$(grep -cxE 'org.jetbrains.completion.full.line|tanvd.grazi|com.intellij.mcpServer' "$lite/disabled_plugins.txt")"
check "Lite vmoptions built from the IDE's own" "-Xmx1536m" "$(grep -- -Xmx "$jb/.config/JetBrains/lite/rustrover-lite.vmoptions")"
check "launcher points the IDE at the Lite profile" \
  "props=$jb/.config/JetBrains/lite/rustrover-lite.properties vm=$jb/.config/JetBrains/lite/rustrover-lite.vmoptions args=proj" \
  "$("$jb/.local/bin/rustrover-lite" proj)"
check "desktop entry named after the product" "Name=RustRover Lite" \
  "$(grep '^Name=' "$jb/.local/share/applications/jetbrains-rustrover-lite.desktop")"
before=$(cat "$main/disabled_plugins.txt" "$lite/disabled_plugins.txt")
HOME="$jb" JETBRAINS_ROOTS="$ide" ./install.sh --only jetbrains >"$tmp/jb2.out" 2>&1
check "second run changes nothing" "$before" "$(cat "$main/disabled_plugins.txt" "$lite/disabled_plugins.txt")"
check "second run says so" "yes" "$(grep -q 'already in place' "$tmp/jb2.out" && echo yes || cat "$tmp/jb2.out")"
rm -rf "$lite"
printf 'x\n' >"$main/disabled_plugins.txt"
HOME="$jb" JETBRAINS_ROOTS="$ide" JETBRAINS_TRIM_MAIN=0 ./install.sh --only jetbrains >/dev/null 2>&1
check "JETBRAINS_TRIM_MAIN=0 leaves the main profile alone" "x" "$(cat "$main/disabled_plugins.txt")"

echo "cli"
check "--list names every component" "9" "$(./install.sh --list | wc -l | tr -d ' ')"
check "unknown component is rejected" "1" "$(./install.sh --only nope >/dev/null 2>&1; echo $?)"
check "unknown option is rejected" "1" "$(./install.sh --frobnicate >/dev/null 2>&1; echo $?)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
