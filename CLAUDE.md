# Working on this overlay

This repository mirrors the layout of github.com/basecamp/omarchy so its files drop into a checkout unchanged (`bin/apply-to-checkout`). Upstream's `AGENTS.md` conventions apply here:

- `#!/bin/bash` shebangs, bash 5 conditionals (`[[ ]]`, `(( ))`), two-space indentation, full `if`/`else` for two-path flow.
- Commands in `bin/` declare `# omarchy:summary=` (plus `args`, `examples`, `requires-sudo=true`, `hidden=true` only when true). The route comes from the filename: `omarchy-hw-dell-xps-ir-camera` is `omarchy hw dell xps ir camera`.
- Use the helpers, not raw tools: `omarchy-pkg-add` / `omarchy-pkg-aur-add` / `omarchy-pkg-drop`, `omarchy-hw-match`, `omarchy-notification-send`.
- `hw-` commands are silent predicates; make sysfs roots overridable through `OMARCHY_*_PATH` variables so tests can fake them.
- Setup and remove wizards keep fixed `/etc` and `/usr` paths; tests retarget a `sed` copy and drive it through stubbed `sudo`, never through environment overrides in the shipped command.
- A privileged heredoc that expands variables needs an `# omarchy:heredoc-expands paths=... -- why` comment directly above it.

Tests are TAP-style files under `test/shell.d/*-test.sh` sourcing `base-test.sh` (`pass`, `skip`, `fail`, `require_command`); `./test/shell` runs them all. Write the failing test first, then the change. Stub the world, run the real script, assert on the files and call log it leaves.

`bin/check` lints and tests, `bin/setup` installs dev dependencies and sets the executable bits, `bin/run` walks through the manual tests on a machine running a linked checkout with the overlay applied (`bin/run probe` probes the camera). Trials use Omarchy's own dev flow (`bin/apply-to-checkout`, `omarchy dev pkg-test`, `omarchy dev link`), never files copied into the system by hand. Strings the shell shows go through `default/i18n/en` catalog keys, as upstream's do. Dev scripts in `bin/` never take a system command's name: a checkout's `bin/` may be first on PATH.
