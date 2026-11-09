#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
log="$test_tmp/calls.log"
output="$test_tmp/output"
conf="$test_tmp/omarchy.conf"
repo="$test_tmp/repo"
mkdir -p "$stub_bin" "$repo/bin" "$repo/packaging/omarchy-dell-xps-face"
sed "s|/etc/omarchy.conf|$conf|g" "$ROOT/bin/install-face" >"$repo/bin/install-face"

cat >"$stub_bin/omarchy-pkg-present" <<'SH'
#!/bin/bash
[[ $TEST_DRIVER == installed ]]
SH
cat >"$stub_bin/pacman" <<'SH'
#!/bin/bash
[[ $TEST_DRIVER == repository ]]
SH
cat >"$stub_bin/omarchy-pkg-add" <<'SH'
#!/bin/bash
printf 'pkg-add %s\n' "$*" >>"$TEST_LOG"
SH
cat >"$stub_bin/git" <<'SH'
#!/bin/bash
printf 'git %s\n' "$*" >>"$TEST_LOG"
if [[ $1 == init ]]; then
  mkdir -p "$3/pkgbuilds/hm1092-ir-camera"
fi
SH
cat >"$stub_bin/makepkg" <<'SH'
#!/bin/bash
printf 'makepkg %s in %s\n' "$*" "${PWD##*/}" >>"$TEST_LOG"
SH
cat >"$stub_bin/omarchy-face-integrate" <<'SH'
#!/bin/bash
printf 'integrate\n' >>"$TEST_LOG"
SH
chmod +x "$stub_bin"/*

invoke() {
  local status=0

  : >"$log"
  env -u OMARCHY_PATH ${TEST_SESSION:+OMARCHY_PATH="$TEST_SESSION"} TEST_LOG="$log" TEST_DRIVER="${1:-installed}" \
    PATH="$stub_bin:/usr/bin:/bin" bash "$repo/bin/install-face" >"$output" 2>&1 || status=$?
  return "$status"
}

printf 'export OMARCHY_PATH="/home/alice/omarchy"\n' >"$conf"
invoke && fail "a dev-linked Omarchy is refused"
grep -q 'omarchy dev unlink' "$output" || fail "unlinking is named" "$(cat "$output")"
[[ ! -s $log ]] || fail "nothing is installed" "$(cat "$log")"

printf 'export OMARCHY_PATH="/usr/share/omarchy"\n' >"$conf"
TEST_SESSION=/home/alice/omarchy invoke && fail "a session still on the checkout is refused"
grep -q 'reboot first' "$output" || fail "the reboot is named" "$(cat "$output")"
[[ ! -s $log ]] || fail "nothing is installed" "$(cat "$log")"
pass "the install waits until the machine really runs the packaged Omarchy"

invoke installed || fail "installing succeeds with the driver present" "$(cat "$output")"
! grep -qE '^(git|pkg-add)|hm1092-ir-camera$' "$log" || fail "a driver that is there is left alone" "$(cat "$log")"
[[ $(tail -n 1 "$log") == integrate ]] || fail "the face takes its place in the shell last" "$(cat "$log")"
grep -q 'makepkg -sfi --noconfirm in omarchy-dell-xps-face' "$log" || fail "the overlay's package is built" "$(cat "$log")"

invoke repository || fail "installing succeeds with the driver in a repository" "$(cat "$output")"
grep -qx 'pkg-add hm1092-ir-camera' "$log" || fail "a repository's driver wins" "$(cat "$log")"
! grep -q '^git' "$log" || fail "nothing is fetched then" "$(cat "$log")"

invoke missing || fail "installing succeeds without the driver anywhere" "$(cat "$output")"
pin=$(sed -n 's/^driver_commit=\([0-9a-f]\{40\}\) .*/\1/p' "$ROOT/bin/install-face")
[[ -n $pin ]] || fail "the driver is pinned to a commit"
grep -q "fetch -q --depth 1 https://github.com/omacom/omarchy-pkgs.git $pin" "$log" || fail "the pinned driver is fetched" "$(cat "$log")"
grep -q 'makepkg -si --noconfirm in hm1092-ir-camera' "$log" || fail "and built" "$(cat "$log")"
(( $(grep -n 'in hm1092-ir-camera' "$log" | cut -d: -f1) < $(grep -n 'in omarchy-dell-xps-face' "$log" | cut -d: -f1) )) ||
  fail "the driver comes first" "$(cat "$log")"
pass "the driver comes from what is installed, then a repository, then the pinned pull request"
