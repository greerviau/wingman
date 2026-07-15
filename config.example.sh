# config.example.sh - template for machine-local wingman overrides.
#
# Copy this to config.local.sh (gitignored) and uncomment/edit what you want:
#   cp config.example.sh config.local.sh
#
# config.local.sh is sourced by bin/lib/common.sh, so every bin/ script picks
# up whatever it sets.

# Default model for crew spawns. An explicit `--model` on a spawn always wins;
# otherwise this is the default; with neither set, the agent CLI's own default
# applies.
# WM_MODEL=opus

# Extra project roots for bin/discover-projects to scan, beyond wingman's own
# parent directory.
# WM_ROOTS="$HOME/dev $HOME/code"

# Project names for bin/discover-projects to skip.
# WM_IGNORE="some-repo-to-skip"

# Pin specific project names to explicit paths ("name|path", newline-separated),
# overriding anything the scan would otherwise find.
# WM_PINS="my-app|$HOME/dev/my-app"
