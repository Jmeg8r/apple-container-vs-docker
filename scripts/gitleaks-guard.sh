#!/usr/bin/env bash
# WHAT: version-asserting wrapper around gitleaks. Asserts the binary on PATH meets
#       GITLEAKS_MIN_VERSION, then execs gitleaks with every argument passed through.
#       With no arguments it performs the assertion only and exits.
#
# WHY: see scripts/gitleaks-version.env. Short version -- a secret scanner whose
#      version you cannot name is a scanner whose coverage you cannot state.
#
# Usage:
#   scripts/gitleaks-guard.sh git --staged --redact --no-banner
#   scripts/gitleaks-guard.sh                # assertion only, no scan
set -euo pipefail

unset CDPATH   # a CDPATH entry would make the `cd` below resolve somewhere else
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)

# die() is defined BEFORE the source on purpose. Sourcing a missing file aborts
# under `set -e`, and if die() lived below that line the failure would surface as
# a bare shell error naming neither this guard nor the file it wanted. Failing
# closed is right; failing anonymously is not. Provisioning copies the version
# file alongside this script, so this only fires once someone deletes or
# unreadable-permissions it — exactly the moment a named cause pays for itself.
die() {
  printf '\n✗ gitleaks-guard: %s\n\n' "$1" >&2
  exit 1
}

VERSION_ENV="$SCRIPT_DIR/gitleaks-version.env"
# -f as well as -r: `[ -r ]` is true for a readable DIRECTORY, and sourcing one
# fails with a shell diagnostic instead of reaching die() — the same anonymous
# failure this check exists to replace. A readable FIFO would be worse still,
# blocking the hook indefinitely rather than failing at all.
[ -f "$VERSION_ENV" ] && [ -r "$VERSION_ENV" ] || die "cannot read $VERSION_ENV
    That file carries GITLEAKS_MIN_VERSION, so without it this guard cannot say
    which scanner it is about to run — and an unidentified scanner is exactly
    what it exists to refuse.
    Restore it from the kit:  10-repo-init.sh --path . --no-remote"
# shellcheck source=scripts/gitleaks-version.env
# shellcheck disable=SC1091  # resolved at runtime; the source= directive above covers -x runs
. "$VERSION_ENV"

if ! command -v gitleaks >/dev/null 2>&1; then
  die "gitleaks is not on PATH.
    This repo's secret scan cannot run, and an unrun scan is not a clean scan.
    Install:  brew install gitleaks"
fi

raw_version=$(gitleaks version 2>/dev/null) || die "\`gitleaks version\` exited non-zero"

# 8.x prints a bare '8.30.1'; other builds prefix a 'v' or add build metadata.
# Take the first semver-shaped token from whatever it printed.
found=$(printf '%s' "$raw_version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)

# Fail CLOSED on unparseable output. An unrecognised version is exactly the case
# this guard exists for -- treating it as "probably fine" would reintroduce the bug.
[ -n "$found" ] && [ -n "${GITLEAKS_MIN_VERSION:-}" ] || die "could not determine the gitleaks version.
    \`gitleaks version\` printed: ${raw_version:-<nothing>}
    Refusing to scan with an unidentified binary."

# Compare the two versions field by field, without `sort -V`.
#
# WHY not sort -V: it is a GNU extension. macOS ships BSD sort, where -V is absent on
# older systems and, worse, has been observed to ACCEPT the flag and sort lexically --
# under which "8.9.0" > "8.30.1" and a too-old gitleaks passes the floor. A version
# gate that silently mis-compares is the same defect class as a scan that reports
# clean without reading anything, so it is computed explicitly here rather than
# delegated to a flag whose semantics vary by platform.
version_lt() {  # version_lt A B -> true when A < B
  local a="$1" b="$2" i av bv
  for i in 1 2 3; do
    av=$(printf '%s' "$a" | cut -d. -f"$i"); bv=$(printf '%s' "$b" | cut -d. -f"$i")
    # Empty or non-numeric fields read as 0, so "8.30" compares as "8.30.0".
    case "$av" in ''|*[!0-9]*) av=0 ;; esac
    case "$bv" in ''|*[!0-9]*) bv=0 ;; esac
    [ "$av" -lt "$bv" ] && return 0
    [ "$av" -gt "$bv" ] && return 1
  done
  return 1
}
! version_lt "$found" "$GITLEAKS_MIN_VERSION" || die "gitleaks $found is older than the required $GITLEAKS_MIN_VERSION.
    Allowlist semantics differ across versions, so the coverage documented in
    .gitleaks.toml does not hold on this binary.
    Upgrade:  brew upgrade gitleaks"

# Assertion-only mode: callers that just want the version gate.
[ "$#" -gt 0 ] || { printf '✓ gitleaks %s (floor %s)\n' "$found" "$GITLEAKS_MIN_VERSION"; exit 0; }

exec gitleaks "$@"
