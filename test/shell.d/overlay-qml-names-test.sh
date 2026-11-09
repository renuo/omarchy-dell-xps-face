#!/bin/bash

# The patched plugins may only read names that exist. A name upstream dropped
# passes every text check and only throws once a scan starts at the lock, so
# this asks qmllint what is unresolved, minus what stock's own file leaves
# unresolved (imports it cannot see) and what the patched file declares.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command python3
qmllint=/usr/lib/qt6/bin/qmllint
stock_shell="${OMARCHY_STOCK_SHELL:-/usr/share/omarchy/shell}"
if [[ ! -x $qmllint || ! -d $stock_shell/plugins/lock ]]; then
  skip "needs qmllint and an installed Omarchy shell"
  exit 0
fi

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

unknown=$(python3 -I - "$qmllint" "$ROOT/shell/plugins" "$stock_shell/plugins" "$test_tmp" <<'PY'
import json, pathlib, re, subprocess, sys

qmllint, ours, stock, tmp = sys.argv[1:]

def unqualified(path):
    report = pathlib.Path(tmp) / "report.json"
    subprocess.run([qmllint, "--json", str(report), path.name], cwd=path.parent, capture_output=True, timeout=120)
    lines = path.read_text().split("\n")
    names = set()
    for found in json.loads(report.read_text())["files"]:
        for warning in found["warnings"]:
            if warning.get("id") != "unqualified":
                continue
            line = lines[warning["line"] - 1][warning["column"] - 1:]
            match = re.match(r"[A-Za-z_]\w*", line)
            if match:
                names.add(match.group())
    return names

def declared(path):
    text = path.read_text()
    return set(re.findall(r"\b(?:property\s+[\w.<>]+|function|signal)\s+(\w+)", text)) \
        | set(re.findall(r"\bid:\s*(\w+)", text)) | set(re.findall(r"^import\s+\S+(?:\s+[\d.]+)?\s+as\s+(\w+)", text, re.M))

for name in ("lock/Service.qml", "lock/LockView.qml", "polkit/PolkitAgent.qml"):
    path = pathlib.Path(ours) / name
    for unknown in sorted(unqualified(path) - unqualified(pathlib.Path(stock) / name) - declared(path)):
        print(f"{name}: {unknown}")
PY
)
[[ -z $unknown ]] || fail "the patched plugins read only names that exist" "$unknown"
pass "the patched plugins read only names stock or the patch declares"
