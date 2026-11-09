#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq
require_command python3

integrate="$ROOT/bin/omarchy-face-integrate"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
log="$test_tmp/calls.log"
output="$test_tmp/output"
home="$test_tmp/home"
share="$test_tmp/share"
stock="$test_tmp/stock"
plugins="$home/.config/omarchy/plugins"
menu="$home/.config/omarchy/extensions/omarchy-menu.jsonc"
hooks="$home/.config/omarchy/hooks/post-update.d"
copy="$test_tmp/integrate"
mkdir -p "$stub_bin" "$share/bin" "$share/install/user/first-run"

grep -Fxq 'share=/usr/share/omarchy-dell-xps-face' "$integrate" || fail "the command names its package's fixed path"
sed "s|^share=.*|share=$share|" "$integrate" >"$copy"

cp "$ROOT/bin/patch-shell-plugins" "$share/bin/"
cp -r "$ROOT/default" "$share/"
cp "$ROOT"/install/user/first-run/*.hook "$share/install/user/first-run/"

for name in omarchy-shell omarchy-plugin-enable omarchy-plugin-disable omarchy-notification-send; do
  # shellcheck disable=SC2016 # the stub's own text
  printf '#!/bin/bash\nprintf "%%s %%s\\n" "${0##*/}" "$*" >>"$TEST_LOG"\n' >"$stub_bin/$name"
done
cat >"$stub_bin/omarchy-plugin-list" <<'SH'
#!/bin/bash
echo '[{"id":"alice.lock"},{"id":"alice.polkit"}]'
SH
cat >"$stub_bin/omarchy-hook-install" <<'SH'
#!/bin/bash
printf 'hook %s\n' "${2##*/}" >>"$TEST_LOG"
mkdir -p "$HOME/.config/omarchy/hooks/$1.d"
cp "$2" "$HOME/.config/omarchy/hooks/$1.d/"
SH
chmod +x "$stub_bin"/*

reset_fixture() {
  rm -rf "$home" "$stock"
  : >"$log"
  mkdir -p "$(dirname "$menu")" "$stock/shell/plugins" "$stock/default/omarchy"
  cp -r "${OMARCHY_STOCK_SHELL:-/usr/share/omarchy/shell}"/plugins/{lock,polkit} "$stock/shell/plugins/"
  chmod -R u+w "$stock"
  printf '{\n  "about": {"label":"About"},\n}\n' >"$stock/default/omarchy/omarchy-menu.jsonc"
  printf '{\n  // mine\n  "personal": {"label":"Personal"},\n}\n' >"$menu"
}

invoke() {
  local status=0

  TEST_LOG="$log" HOME="$home" USER=alice OMARCHY_PATH="$stock" PATH="$stub_bin:/usr/bin:/bin" \
    bash "$copy" "$@" >"$output" 2>&1 || status=$?
  return "$status"
}

jsonc() {
  sed -E '/^[[:space:]]*\/\//d' "$1" | sed -E ':a;N;$!ba;s/,([[:space:]]*[]}])/\1/g'
}

if [[ ! -d ${OMARCHY_STOCK_SHELL:-/usr/share/omarchy/shell}/plugins/lock ]]; then
  skip "no installed Omarchy shell to clone"
  exit 0
fi

reset_fixture
invoke || fail "integrating succeeds on the installed Omarchy" "$(cat "$output")"
for name in lock polkit; do
  jq -e --arg id "alice.$name" --arg source "omarchy.$name" \
    '.id == $id and .omarchy.clonedFrom == $source and .omarchy.faceOverlay == true and (.omarchy.capabilities | index("authentication"))' \
    "$plugins/alice.$name/manifest.json" >/dev/null || fail "the $name clone keeps its trust and is marked ours" "$(cat "$plugins/alice.$name/manifest.json")"
  grep -qx "omarchy-plugin-enable alice.$name" "$log" || fail "the $name clone replaces the built-in" "$(cat "$log")"
done
[[ -f $plugins/alice.lock/FaceModel.js && -f $plugins/alice.lock/poster.sh ]] || fail "the clone holds the patch and stock's other files"
grep -qF 'I18n.t("lock.faceRefused", "Face refused")' "$plugins/alice.lock/Service.qml" ||
  fail "the clone carries the words stock's catalog lacks" "$(grep -n faceRefused "$plugins/alice.lock/Service.qml")"
grep -qF 't("lock.faceOrPassword", "Face or Password")' "$plugins/alice.lock/FaceModel.js" || fail "the model carries them too"
[[ -z $(find "$plugins" -maxdepth 1 -name '.face.*') ]] || fail "no stage is left behind"
pass "the clones are patched from the installed Omarchy and keep their trust"

jq -e 'has("personal") and has("setup.security.face") and has("remove.security.face")' <<<"$(jsonc "$menu")" >/dev/null ||
  fail "the rows land in the user's menu, which stays valid" "$(cat "$menu")"
[[ -x $hooks/face-integrate.hook && -x $hooks/setup-face.hook ]] || fail "the hooks are installed" "$(ls "$hooks" 2>&1)"
pass "the menu rows and the post-update hooks are in place"

: >"$log"
invoke || fail "integrating again succeeds" "$(cat "$output")"
[[ ! -s $log ]] || fail "nothing changes while Omarchy has not moved, so a running lock is not reloaded" "$(cat "$log")"
(( $(grep -c '"setup.security.face"' "$menu") == 1 )) || fail "the rows are added once" "$(cat "$menu")"
pass "integrating again changes nothing"

echo '// moved' >>"$stock/shell/plugins/lock/poster.sh"
invoke || fail "integrating after an update succeeds" "$(cat "$output")"
grep -qx 'omarchy-plugin-enable alice.lock' "$log" || fail "the moved clone is published" "$(cat "$log")"
! grep -q 'alice.polkit' "$log" || fail "the unmoved clone stays" "$(cat "$log")"
grep -qF '// moved' "$plugins/alice.lock/poster.sh" || fail "the clone follows stock"
pass "an update regenerates only the clone that moved"

: >"$log"
sed -i 's/function runWake() {/function wakeDisplays() {/' "$stock/shell/plugins/lock/Service.qml"
sed -i 's/property bool fingerprintConfigured: false/property bool readerConfigured: false/' "$stock/shell/plugins/lock/Service.qml"
invoke && fail "a stock lock the patch no longer fits fails"
[[ ! -e $plugins/alice.lock && ! -e $plugins/alice.polkit ]] || fail "the shell falls back to stock's lock and polkit" "$(ls -A "$plugins")"
grep -qx 'omarchy-plugin-disable alice.lock' "$log" || fail "the clone is disabled" "$(cat "$log")"
grep -q 'omarchy-notification-send .*Face unlock is off' "$log" || fail "the owner is told" "$(cat "$log")"
grep -q 'password works' "$log" || fail "and told the password still works" "$(cat "$log")"
pass "a stock lock the patch no longer fits falls back to stock and says so"

reset_fixture
mkdir -p "$plugins/alice.lock"
printf '{"id":"alice.lock","omarchy":{"clonedFrom":"omarchy.lock"}}\n' >"$plugins/alice.lock/manifest.json"
echo mine >"$plugins/alice.lock/mine"
invoke && fail "a clone of the owner's own stops the integration"
[[ -f $plugins/alice.lock/mine ]] || fail "the owner's clone survives"
grep -q 'your own clone' "$output" || fail "the owner's clone is named" "$(cat "$output")"
pass "the owner's own clone is never overwritten"

reset_fixture
invoke || fail "integrating succeeds" "$(cat "$output")"
: >"$log"
invoke --remove || fail "removing succeeds" "$(cat "$output")"
[[ ! -e $plugins/alice.lock && ! -e $plugins/alice.polkit ]] || fail "removal drops the clones" "$(ls -A "$plugins")"
! grep -q 'security.face' "$menu" || fail "removal drops the rows" "$(cat "$menu")"
grep -q '"personal"' "$menu" || fail "the user's own rows stay"
[[ ! -e $hooks/face-integrate.hook && ! -e $hooks/setup-face.hook ]] || fail "removal drops the hooks"
pass "removal leaves stock's lock, polkit dialog and menu"

reset_fixture
echo '// upstream' >"$stock/shell/plugins/lock/FaceModel.js"
printf '{\n  "setup.security.face": {"label":"Face"},\n}\n' >"$stock/default/omarchy/omarchy-menu.jsonc"
invoke || fail "integrating on an Omarchy with the face succeeds" "$(cat "$output")"
[[ ! -e $plugins/alice.lock ]] || fail "an Omarchy that carries the face needs no clones" "$(ls -A "$plugins")"
! grep -q 'security.face' "$menu" || fail "and no menu rows" "$(cat "$menu")"
pass "an Omarchy that carries the face itself needs none of this"
