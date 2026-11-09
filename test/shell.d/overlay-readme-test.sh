#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command python3

mapfile -t images < <(grep -o '<img src="[^"]*"' "$ROOT/README.md" | sed 's/<img src="//; s/"$//')
(( ${#images[@]} == 3 )) || fail "the README shows a pictogram for sudo, polkit and the lock screen" "${images[*]}"
for image in "${images[@]}"; do
  [[ -f $ROOT/$image ]] || fail "the README's $image exists"
  python3 -I - "$ROOT/$image" <<'PY' || fail "$image is an SVG with a title and a description for screen readers"
import sys, xml.etree.ElementTree as ET
ns = "{http://www.w3.org/2000/svg}"
root = ET.parse(sys.argv[1]).getroot()
sys.exit(0 if root.tag == ns + "svg" and root.find(ns + "title") is not None and root.find(ns + "desc") is not None else 1)
PY
done
grep -q 'alt="[^"]\+"' <<<"$(grep '<img ' "$ROOT/README.md")" || fail "every pictogram has alt text"
(( $(grep -c '<img [^>]*alt="[^"]\+"' "$ROOT/README.md") == 3 )) || fail "every pictogram has alt text"
pass "the README's pictograms exist, parse, and describe themselves"

# The driver package lives in omarchy-pkgs; the overlay keeps no copy of it. The
# face's own gate stands in for the fingerprint fix in omarchy#15685.
for pr in 'omacom/omarchy-pkgs/pull/1213' 'omacom/omarchy/pull/15685'; do
  grep -qF "$pr" "$ROOT/README.md" || fail "the README links $pr"
done
grep -qF 'omarchy channel set edge' "$ROOT/README.md" || fail "the README names the edge channel the driver's kernel is on"
[[ ! -e $ROOT/packaging/hm1092-ir-camera ]] || fail "the overlay carries no copy of the driver package"
pass "the README builds on the driver package, which lives upstream, and names the fingerprint fix the face's gate replaces"
