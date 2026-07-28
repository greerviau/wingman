# config.example.sh - template for the raw shell escape hatch.
#
# For everyday settings use config.local.toml instead (see
# config.example.toml): it is declarative, validated by `bin/config --check`,
# and `bin/config` can explain where every resolved value came from. It covers
# onboarding preferences, per-crew-type models and effort, project discovery,
# and the harness knobs - including everything this file used to hold.
#
# This file is for what that one deliberately does not model: the many
# undocumented WM_* tuning knobs (timings, thresholds, detector regexes) that
# exist only for the rare case of tuning wingman's own internals. Being
# arbitrary shell, it can set any of them.
#
#   cp config.example.sh config.local.sh
#
# config.local.sh is sourced by bin/lib/common.sh BEFORE config.local.toml is
# applied, so anything set here wins over that file - sourcing this file is
# literally setting the environment, and the environment outranks the settings
# file. Both are gitignored.

# Seconds between the spawn of a crew window and the delivery of its first
# message (bin/spawn-crew).
# WM_SPAWN_DELAY=2

# Seconds an apparently-idle crew member goes unheard before the watcher nudges
# it, and then flips it to `stalled` (bin/watch-fleet).
# WM_STALL_IDLE=180

# Seconds between watcher polls.
# WM_WATCH_INTERVAL=5

# Grep the source for '${WM_' to find the rest; each is documented at its point
# of use.
