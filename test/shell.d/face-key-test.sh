#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command python3

key="$ROOT/bin/omarchy-face-key"
test_tmp=$(mktemp -d)
pids=()
cleanup() {
  (( ${#pids[@]} == 0 )) || kill "${pids[@]}" 2>/dev/null || true
  rm -rf "$test_tmp"
}
trap cleanup EXIT

copy="$test_tmp/face-key"
log="$test_tmp/calls.log"
service_log="$test_tmp/service.log"
me=$(id -un)
mkdir -p "$test_tmp/dev/input" "$test_tmp/sys/class/input" "$test_tmp/bin"

# The service names root's socket, the kernel's input trees, the face policy
# and the notification tools; a scratch copy retargets each, and idles out
# after a second instead of thirty.
for literal in 'SOCKET_PATH = "/run/omarchy-face-key.sock"' 'INPUT_DIR = "/dev/input"' 'INPUT_SYSFS = "/sys/class/input"' \
  'FACE_CONF = "/etc/omarchy/face.conf"' 'SETPRIV = "/usr/bin/setpriv"' 'NOTIFY = "/usr/bin/omarchy-notification-send"' 'IDLE_EXIT_S = 30'; do
  (( $(grep -Fxc "$literal" "$key") == 1 )) || fail "the service names $literal exactly once"
done
sed -e "s|^SOCKET_PATH = .*|SOCKET_PATH = \"$test_tmp/key.sock\"|" \
  -e "s|^INPUT_DIR = .*|INPUT_DIR = \"$test_tmp/dev/input\"|" \
  -e "s|^INPUT_SYSFS = .*|INPUT_SYSFS = \"$test_tmp/sys/class/input\"|" \
  -e "s|^FACE_CONF = .*|FACE_CONF = \"$test_tmp/face.conf\"|" \
  -e "s|^SETPRIV = .*|SETPRIV = \"$test_tmp/bin/setpriv\"|" \
  -e "s|^IDLE_EXIT_S = .*|IDLE_EXIT_S = 1|" "$key" >"$copy"
pass "the service names its fixed paths once each, and the test drives a retargeted copy"

# The service hands the notifier a clean environment, so the stub logs to a
# path fixed here.
cat >"$test_tmp/bin/setpriv" <<SH
#!/bin/bash
{ printf 'setpriv'; printf ' %s' "\$@"; printf '\n'; } >>"$log"
SH
chmod +x "$test_tmp/bin/setpriv"

# input <event> <device path under sys> <key capabilities>: a sysfs entry and
# a FIFO standing in for its evdev node.
input() {
  mkdir -p "$test_tmp/sys/$2/capabilities" "$test_tmp/sys/class/input/$1"
  printf '%s\n' "$3" >"$test_tmp/sys/$2/capabilities/key"
  ln -s "$test_tmp/sys/$2" "$test_tmp/sys/class/input/$1/device"
  mkfifo "$test_tmp/dev/input/$1"
}
# Bit 193 (F23, the Copilot key) is bit 1 of the fourth long from the right.
input event3 devices/platform/i8042/serio0/input/input3 "2 0 0 0"
input event4 devices/virtual/input/input30 "2 0 0 0"
input event5 devices/platform/i8042/serio1/input/input4 "0 0 0 fffffffe"
# Held read-write, the node always has a writer, as a real keyboard does;
# the processes under test are started without it.
exec 7<>"$test_tmp/dev/input/event3"

# until_true <tries of 0.1s> <command...>
until_true() {
  local tries=$1
  shift
  while (( tries-- > 0 )); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}

running() {
  kill -0 "$1" 2>/dev/null
}

gone() {
  ! kill -0 "$1" 2>/dev/null
}

# holds <pid> <path>: whether the process has the file open.
holds() {
  local fd
  for fd in /proc/"$1"/fd/*; do
    [[ $(readlink "$fd") == "$2" ]] && return 0
  done
  return 1
}

# reading <event>: whether the service holds the node open.
reading() {
  holds "$service" "$test_tmp/dev/input/$1"
}

not_reading() {
  ! reading "$1"
}

logged_at_least() {
  (( $(grep -c -- "$1" "$service_log") >= $2 ))
}

# event <value> [code]: one evdev record on the keyboard.
event() {
  python3 -c 'import struct, sys; sys.stdout.buffer.write(struct.pack("llHHi", 0, 0, 1, int(sys.argv[2]), int(sys.argv[1])))' "$1" "${2:-193}" >&7
}

# prompt: a process standing in for a PAM conversation (sudo, polkit, the lock).
prompt() {
  sleep 300 &
  prompt_pid=$!
  pids+=("$prompt_pid")
}

# terminal_prompt: a conversation reading a terminal of its own, as sudo reads
# the user's.
terminal_prompt() {
  rm -f "$test_tmp/terminal-prompt"
  python3 -c 'import os, pty, sys
pid, _ = pty.fork()
if pid == 0:
    os.execvp("sleep", ["sleep", "300"])
print(pid, flush=True)
os.waitpid(pid, 0)' >"$test_tmp/terminal-prompt" 7<&- &
  pids+=("$!")
  until_true 30 test -s "$test_tmp/terminal-prompt" || fail "a conversation with a terminal starts"
  prompt_pid=$(<"$test_tmp/terminal-prompt")
  pids+=("$prompt_pid")
  prompt_tty=$(readlink "/proc/$prompt_pid/fd/0")
}

# waiter <pam pid> [args...]: a prompt waiting for the key.
waiter() {
  local pam_pid=$1
  shift
  python3 "$copy" wait --pam-pid "$pam_pid" --user "$me" "$@" >"$test_tmp/waiter-$pam_pid" 2>&1 7<&- &
  waiter_pid=$!
  pids+=("$waiter_pid")
}

exited_with() {
  local status=0
  until_true 30 gone "$1" || return 1
  wait "$1" || status=$?
  (( status == $2 ))
}

key_take() {
  python3 "$copy" take --pam-pid "$1"
}

printf 'LOCK_WINDOW_MINUTES="15"\n' >"$test_tmp/face.conf"
cp /usr/bin/sleep "$test_tmp/sudo"
"$test_tmp/sudo" 300 &
sudo_pid=$!
pids+=("$sudo_pid")
bash -c 'exec -a /usr/lib/polkit-1/polkit-agent-helper-1 sleep 300' &
polkit_pid=$!
pids+=("$polkit_pid")
until_true 30 grep -q polkit-agent-helper-1 "/proc/$polkit_pid/cmdline" || fail "the stand-in polkit helper starts"
# The copy loaded as a module, for the pieces a run cannot reach.
cat >"$test_tmp/load.py" <<'PY'
import importlib.machinery, importlib.util, os, sys
loader = importlib.machinery.SourceFileLoader("face_key", os.environ["TEST_COPY"])
key = importlib.util.module_from_spec(importlib.util.spec_from_loader("face_key", loader))
loader.exec_module(key)
PY
export TEST_COPY="$copy" TEST_LOAD="$test_tmp/load.py"

TEST_TMP="$test_tmp" python3 - "$sudo_pid" "$$" "$polkit_pid" <<'PY' || fail "the service's pieces behave"
import os
exec(open(os.environ["TEST_LOAD"]).read())
conf = os.path.join(os.environ["TEST_TMP"], "face.conf")

def check(condition, description):
    if not condition:
        print(f"not ok - {description}", file=sys.stderr)
        sys.exit(1)

check(key.window_seconds() == 15 * 60, "the lock's wait ends with the policy's window")
for text, minutes in (("", 60), ("LOCK_WINDOW_MINUTES=0\n", 60), ("LOCK_WINDOW_MINUTES=1.5\n", 60), ("LOCK_WINDOW_MINUTES=2\n", 2)):
    open(conf, "w").write(text)
    check(key.window_seconds() == minutes * 60, f"window from {text!r} is {minutes} minutes, as the lock screen reads it")
os.remove(conf)
check(key.window_seconds() == 3600, "without a policy the window is an hour")

sudo_pid, test_pid, polkit_pid = (int(a) for a in sys.argv[1:])
check(key.beyond_sudo(sudo_pid) == test_pid, "the lock's conversation is whoever ran sudo")
check(key.beyond_sudo(test_pid) == test_pid, "a conversation that is not sudo stays itself")
check(key.describe(polkit_pid) == "a polkit dialog", "polkit's helper is described as its dialog")
check(key.has_key("2 0 0 0".split(), 193) and not key.has_key("0 2 0 0".split(), 193) and not key.has_key(["2"], 193),
      "the Copilot key is found in the kernel's capability bitmap")

# pam_exec runs the helper in a session of its own, without a terminal; the
# answer goes to the one the conversation reads, as sudo reads the user's.
import fcntl, subprocess, termios
master, slave = os.openpty()
reading = subprocess.Popen(["sleep", "30"], stdin=slave, start_new_session=True,
                           preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
alone = subprocess.Popen(["sleep", "30"], stdin=subprocess.DEVNULL, start_new_session=True)
check(key.conversation_tty(reading.pid) == os.ttyname(slave), "the answer goes to the terminal the conversation reads")
check(key.conversation_tty(alone.pid) is None, "a conversation without a terminal, like polkit's helper, gets no typed answer")
real_stat = key.proc_stat
key.proc_stat = lambda pid: ["S", "1", "1", "1", str(os.makedev(136, 999999))]
try:
    key.conversation_tty(reading.pid)
    check(False, "a terminal without a node fails instead of offering a key that cannot answer")
except OSError:
    pass
key.proc_stat = real_stat
reading.kill()
alone.kill()

calls = []
key.fcntl.ioctl = lambda fd, request, arg: calls.append((request, arg))
for kill, typed in ((b"\x15", [b"\x15", b"\n"]), (b"\0", [b"\n"])):
    calls.clear()
    key.termios.tcgetattr = lambda fd, kill=kill: [0] * 6 + [{key.termios.VKILL: kill}]
    key.clear_and_submit(99)
    check([arg for _, arg in calls] == typed and all(request == key.termios.TIOCSTI for request, _ in calls),
          f"the key clears the line with its kill character {kill!r} and submits it empty")
PY
pass "the lock's window, the requester's name and sudo's terminal answer are computed as intended"

# The service speaks over a Unix socket; a sandbox without them cannot run it.
if ! python3 -c 'import socket; socket.socket(socket.AF_UNIX).close()' 2>/dev/null; then
  skip "Unix sockets are unavailable here; the service itself is not exercised"
  exit 0
fi

python3 "$copy" serve 2>"$service_log" 7<&- &
service=$!
pids+=("$service")
until_true 30 test -S "$test_tmp/key.sock" || fail "the service listens" "$(cat "$service_log")"
[[ $(stat -c %a "$test_tmp/key.sock") == 600 ]] || fail "only the service's own account may connect" "$(stat -c %a "$test_tmp/key.sock")"
not_reading event3 || fail "the keyboard stays closed while nothing waits"
pass "the service listens on a private socket and leaves the keyboard alone while nothing waits"

prompt
a=$prompt_pid
waiter "$a"
wa=$waiter_pid
until_true 30 reading event3 || fail "a waiting prompt opens the keyboard" "$(cat "$service_log")"
not_reading event4 || fail "a uinput keyboard under /devices/virtual is never read"
not_reading event5 || fail "a keyboard without the Copilot key is never read"
grep -q 'sleep 300 (from bash) waits for the key' "$service_log" || fail "each waiting prompt is logged with its requester" "$(cat "$service_log")"
event 0
event 2
event 1 28
sleep 0.3
running "$wa" || fail "a release, an autorepeat or another key is no press" "$(cat "$test_tmp/waiter-$a")"
event 1
exited_with "$wa" 0 || fail "the Copilot key releases the one waiting prompt" "$(cat "$test_tmp/waiter-$a" "$service_log")"
key_take "$a" || fail "the prompt the key released may take the press"
key_take "$a" && fail "a press serves one scan only"
until_true 30 not_reading event3 || fail "the keyboard closes again once nothing waits"
pass "only a Copilot key press on a physical keyboard releases a waiting prompt, once"

prompt
b=$prompt_pid
waiter "$b"
wb=$waiter_pid
until_true 30 reading event3 || fail "the next prompt reopens the keyboard"
key_take "$b" && fail "a prompt answered without the key gets no scan"
exited_with "$wb" 1 || fail "an answered prompt stops waiting" "$(cat "$test_tmp/waiter-$b")"
prompt
c=$prompt_pid
waiter "$c"
wc=$waiter_pid
until_true 30 reading event3 || fail "a prompt waits again"
python3 "$copy" drop --pam-pid "$c" || fail "dropping a prompt succeeds"
exited_with "$wc" 1 || fail "a prompt answered with a password stops waiting" "$(cat "$test_tmp/waiter-$c")"
prompt
d=$prompt_pid
waiter "$d"
wd=$waiter_pid
until_true 30 reading event3 || fail "a prompt waits once more"
kill "$d"
exited_with "$wd" 1 || fail "a prompt whose conversation ended stops waiting" "$(cat "$test_tmp/waiter-$d")"
prompt
r=$prompt_pid
waiter "$r"
first=$waiter_pid
until_true 30 reading event3 || fail "a prompt waits before asking again"
waiter "$r"
second=$waiter_pid
exited_with "$first" 1 || fail "a conversation asking again replaces its earlier prompt" "$(cat "$service_log")"
event 1
exited_with "$second" 0 || fail "the prompt that replaced it gets the key alone" "$(cat "$service_log")"
key_take "$r" || fail "the replacing prompt may take the press"
pass "a prompt stops waiting once it is answered, dropped, gone or asked again"

: >"$log"
waits=$(grep -c 'waits for the key' "$service_log")
prompt
e=$prompt_pid
prompt
f=$prompt_pid
waiter "$e"
we=$waiter_pid
waiter "$f" --lock
wf=$waiter_pid
until_true 30 logged_at_least 'waits for the key' $((waits + 2)) || fail "both prompts wait" "$(cat "$service_log")"
event 1
until_true 30 logged_at_least 'key refused' 1 || fail "the press is refused" "$(cat "$service_log")"
{ running "$we" && running "$wf"; } || fail "a press with two prompts waiting releases neither, and both keep waiting" "$(cat "$service_log")"
key_take "$e" && fail "neither of two waiting prompts may take the press"
until_true 30 grep -qxF "Face refused: another program is waiting for the Copilot key too" "$test_tmp/waiter-$f" ||
  fail "the lock screen is told why its face was refused" "$(cat "$test_tmp/waiter-$f")"
until_true 30 grep -q 'Face scan refused' "$log" || fail "the user is notified" "$(cat "$log")"
grep -q "setpriv --reuid=$(id -u) --regid=$(id -g) --init-groups /usr/bin/omarchy-notification-send -u critical" "$log" ||
  fail "the notification runs as the user" "$(cat "$log")"
(( $(grep -c '^• sleep 300 (from bash)' "$log") == 2 )) || fail "the notification names both requesters" "$(cat "$log")"
exited_with "$we" 1 || fail "the prompt answered without the key stops waiting"
event 1
exited_with "$wf" 0 || fail "once one prompt is left, the key releases it" "$(cat "$test_tmp/waiter-$f" "$service_log")"
pass "a press with several prompts waiting serves none, keeps them waiting and names them to the user"

terminal_prompt
g=$prompt_pid
presses=$(grep -c 'key pressed for' "$service_log")
start=$(date +%s%N)
setsid -w python3 "$copy" wait --pam-pid "$g" --user "$me" --detach --tty </dev/null >/dev/null 2>&1 7<&- ||
  fail "a detached prompt registers and returns"
(( ($(date +%s%N) - start) < 2000000000 )) || fail "registering does not wait for the key"
until_true 30 reading event3 || fail "the detached prompt waits"
detached=$(pgrep -f -- "wait --pam-pid $g --user") || fail "the detached prompt keeps running"
holds "$detached" "$prompt_tty" ||
  fail "the detached prompt, in a session of its own like pam_exec's child, holds the terminal the conversation reads" "$(ls -l "/proc/$detached/fd")"
event 1
until_true 30 logged_at_least 'key pressed for' $((presses + 1)) || fail "the detached prompt is released" "$(cat "$service_log")"
key_take "$g" || fail "the detached prompt's press is there for the helper to take"
pass "a detached prompt keeps waiting in the background and its press can be taken"

prompt
status=0
timeout 5 bash -c "python3 '$copy' wait --lock --pam-pid $prompt_pid --user $me | true" || status=$?
(( status != 124 )) || fail "a lock prompt whose conversation closed its end stops waiting"
prompt
python3 - "$prompt_pid" "$me" <<'PY' || fail "a lock prompt stops waiting once the window since locking closes"
import os, time
exec(open(os.environ["TEST_LOAD"]).read())
key.window_seconds = lambda: 0.5
start = time.monotonic()
status = key.main(["wait", "--lock", "--pam-pid", sys.argv[1], "--user", sys.argv[2]])
sys.exit(0 if status == 2 and time.monotonic() - start < 3 else 1)
PY
pass "the lock screen's prompt stops waiting when its PAM conversation goes away or its window closes"


until_true 100 gone "$service" || fail "the service exits once nothing has waited for a while"
pass "the service idles out, so it only runs while a prompt offers the face"
