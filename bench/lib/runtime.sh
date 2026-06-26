#!/usr/bin/env bash
# WHAT: Runtime adapter. Maps a logical runtime name to its CLI and ensures the
#       correct engine is the active one before a run.
# WHY:  OrbStack and Docker Desktop BOTH answer to `docker` and cannot run at the
#       same time. We must explicitly activate the intended engine and verify it,
#       or results get silently attributed to the wrong runtime.
set -euo pipefail

# Echo the container CLI binary for a runtime.
runtime_cli() {
  case "$1" in
    apple-container) echo "container" ;;
    docker-desktop|orbstack) echo "docker" ;;
    *) echo "ERROR: unknown runtime '$1'" >&2; return 1 ;;
  esac
}

# Make the named runtime the active engine, then VERIFY it actually answered.
# Returns non-zero (and the scenario is skipped + logged) if it can't be activated.
runtime_activate() {
  local rt="$1"
  case "$rt" in
    apple-container)
      command -v container >/dev/null || { echo "container not installed" >&2; return 1; }
      container system start >/dev/null 2>&1 || true
      ;;
    docker-desktop)
      # Point docker context at Docker Desktop and confirm the server identifies as such.
      docker context use desktop-linux >/dev/null 2>&1 || true
      docker info --format '{{.Name}}' 2>/dev/null | grep -qi 'desktop' \
        || { echo "Docker Desktop not the active docker engine" >&2; return 1; }
      ;;
    orbstack)
      command -v orbctl >/dev/null || { echo "OrbStack not installed" >&2; return 1; }
      orbctl start >/dev/null 2>&1 || true
      docker context use orbstack >/dev/null 2>&1 || true
      docker info --format '{{.Name}}' 2>/dev/null | grep -qi 'orbstack' \
        || { echo "OrbStack not the active docker engine" >&2; return 1; }
      ;;
    *) echo "unknown runtime '$rt'" >&2; return 1 ;;
  esac
}

# Remove a container by name, ignoring errors (used for clean teardown between reps).
runtime_rm() {
  local rt="$1" name="$2" cli; cli="$(runtime_cli "$rt")"
  "$cli" rm -f "$name" >/dev/null 2>&1 || true
}
