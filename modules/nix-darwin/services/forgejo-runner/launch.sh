#!/bin/sh
# The daemon's entrypoint, installed at a FIXED path on the root volume so the
# plist's bytes never change between generations: nix-darwin reloads a daemon
# exactly when its plist differs, and reloading this one cancels every job the
# runner is executing -- including the deploy that is reloading it.
#
# Everything generation-specific is reached through /run/current-system, which
# an activation re-points without telling launchd. That indirection also covers
# a late /nix mount at boot, so no wait4path is needed.
start=/run/current-system/sw/bin/forgejo-runner-start
until [ -x "$start" ]; do /bin/sleep 1; done
exec "$start"
