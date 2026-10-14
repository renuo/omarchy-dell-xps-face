#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# A checkout's bin/ can sit first on PATH, so a dev script named like a system
# command runs in its place: bin/install once caught apply-to-checkout's and
# makepkg's install calls.
for script in "$ROOT"/bin/*; do
  name=${script##*/}
  [[ $name != omarchy-* ]] || continue
  for dir in /usr/bin /usr/sbin /bin /sbin; do
    [[ ! -e $dir/$name ]] || fail "bin/$name shadows $dir/$name"
  done
done
pass "no dev script in bin/ is named like a system command"
