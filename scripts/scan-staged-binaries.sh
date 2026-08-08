#!/usr/bin/env bash
# WHAT: Second-pass secret scan over staged binary/document files that the
#       primary `secrets` gate provably does not inspect. That gate now runs
#       `scripts/gitleaks-guard.sh git --staged`; it previously ran
#       `gitleaks protect --staged`, and `protect` is a deprecated alias. The
#       distinction does not change what this script does — both forms inherit
#       the same path allowlist, which is the hole below.
#
# WHY:  gitleaks' built-in allowlist -- inherited by .gitleaks.toml via
#       `[extend] useDefault = true` -- skips pdf/xlsx/docx/bin/exe/... BY PATH.
#       The primary gate therefore prints "no leaks found" after scanning ~0
#       bytes of them. Verified 2026-08-08 with gitleaks 8.30.1: an AWS key pair
#       in a staged .pdf passes the pre-commit gate untouched. A green check that
#       inspected nothing is the failure this closes.
#
# HOW:  Both mechanisms defeat the path allowlist by changing the PATH, not the
#       config -- so .gitleaks.toml stays the single source of truth and the full
#       built-in ruleset stays active. Nothing is duplicated, nothing can drift.
#
#         OOXML/archives -> copy to a *.zip temp name, which the built-in
#                           allowlist does not match, then let gitleaks'
#                           --max-archive-depth traverse it natively.
#         PDF            -> pdftotext to text, then `gitleaks stdin`.
#                           Raw bytes are NOT enough: content streams are
#                           deflated, so a raw scan of a real PDF reads 0 bytes.
#
# CONTRACT: every file lands in exactly one bucket, and the bucket counts are
#       printed. A zero count reads as UNKNOWN, never as clean.
#
# RESIDUAL LIMIT, stated plainly: a scanned/image-only PDF carries no text
#       layer. pdftotext returns nothing but page separators, which this script
#       reports as UNKNOWN rather than clean. A MOSTLY-image PDF that happens to
#       carry a little real text is the one case that still reads as inspected
#       while its images go unread -- OCR is the only fix for that, and it is not
#       worth the dependency yet.
# TODO(james): revisit if a repo starts committing scanned documents routinely.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CONFIG="$REPO_ROOT/.gitleaks.toml"

# `git diff --cached --name-only` prints paths relative to the REPO ROOT, but
# `git cat-file blob :<path>` resolves :<path> relative to the CURRENT DIRECTORY.
# Those agree only when invoked from the root -- which lefthook does today, so this
# is defensive. Run from a subdirectory the blob lookup fails and, under `set -e`,
# aborts the whole scan: a security gate that exits non-zero for a reason unrelated
# to any finding. Anchoring here makes the two agree wherever it is invoked from.
cd "$REPO_ROOT" || { echo "  ✗ cannot cd to repo root $REPO_ROOT" >&2; exit 1; }

# Archive-shaped documents. gitleaks can read inside these once the path
# allowlist stops skipping them, so they are fully inspectable.
# shellcheck disable=SC2034  # read indirectly by in_list; see its definition
ARCHIVE_EXTS=(xlsx xlsm docx docm pptx pptm odt ods odp jar war zip)

# Text-extractable documents. Need an external extractor.
# shellcheck disable=SC2034  # read indirectly by in_list; see its definition
PDF_EXTS=(pdf)

# PLAIN TEXT that gitleaks' BUILT-IN allowlist skips by path anyway.
#
# Removing `svg` from .gitleaks.toml was necessary and NOT sufficient -- the same
# trap as pdf. Measured 2026-08-08 on 8.30.1: identical token in a.txt and a.svg,
# scanned with this repo's config, flags ONLY a.txt; via `gitleaks stdin`, the svg
# is flagged. So the surviving exclusion is upstream, inherited through
# `[extend] useDefault`, and no local edit reaches it.
#
# These need no extraction -- they are already text. They just need to arrive by a
# route the path allowlist cannot match, which is exactly what stdin is.
# shellcheck disable=SC2034  # read indirectly by in_list; see its definition
TEXT_ALLOWLISTED_EXTS=(svg)

# Formats no text scanner can meaningfully read. Reported, never inspected,
# and deliberately NOT blocking -- a credential in a screenshot is invisible to
# a text scanner either way, so blocking here buys noise, not coverage.
# shellcheck disable=SC2034  # read indirectly by in_list; see its definition
# NOTE: svg is deliberately ABSENT. It is XML text, not an opaque raster -- a
# credential in a <text>, <desc> or <metadata> node is plain readable content. It
# was listed here AND allowlisted in .gitleaks.toml, so it had no scanning gate at
# all. Both exclusions were removed together; the justification for keeping the
# raster formats ("invisible to a text scanner either way") was never true of SVG.
OPAQUE_EXTS=(png jpg jpeg gif webp ico bmp tif tiff avif heic
             mp3 mp4 mov avi mkv wav aiff flac
             exe dll so dylib bin dmg pkg iso
             woff woff2 ttf otf eot
             fbx blend casc obj glb gltf psd ai sketch
             pyc pdb class o a)

MAX_ARCHIVE_DEPTH=5

inspected=0        # files actually read by a scanner
inspected_bytes=0  # bytes those scanners actually consumed
opaque=()          # not inspectable by any text scanner
unknown=()         # SHOULD have been inspectable but was not -- fails the gate
leaks=0
archive_canary=""  # "" not probed | ok | bad | nopython | buildfail | norule
pdf_canary=""

TMPDIR_SCAN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SCAN"' EXIT

# Split so the literal never appears as a matchable token in this file -- it
# would otherwise trip the coderabbit-api-key rule when this script is staged.
CANARY_TOKEN="cr-""canary0123456789abcdefghij"

# This script calls `gitleaks` directly rather than through gitleaks-guard.sh --
# deliberately, and gitleaks-version.env explains why at length: the canaries read
# `exit 1` as "the toolchain works", and the guard also exits 1 when it rejects a
# version, so routing through it would turn a version failure into a false OK.
#
# What this script needs is SUBCOMMAND support -- `stdin`, `dir`, and
# --max-archive-depth -- none of which exist on the 1.x line (a reviewer's sandbox
# reported 1.7.3). Rather than parse a version string or trust --help -- a summary,
# not a contract -- assert BEHAVIOR: push a known secret through the exact code path
# we rely on and require a hit. No hit means the toolchain cannot do the job, which
# is UNKNOWN, never clean.
#
# The probes distinguish "the path is broken" from "the probe could not be built",
# because those send you to different places. Collapsing them is what made a missing
# python3 tell the developer to upgrade a gitleaks that was already correct -- note
# the asymmetry that made it so misleading: the real archive scan needs no python3
# at all, only the probe does. canary_archive_ok documents its exact codes above
# its definition; keep that list and the caller's case statement in step.
canary_stdin_ok() {
  local rc=0
  printf 'token %s\n' "$CANARY_TOKEN" \
    | gitleaks stdin --no-banner --redact --config "$CONFIG" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ]
}

# Returns:
#   0 = archive traversal works
#   1 = gitleaks cannot traverse archives
#   2 = python3 is absent, so the probe could not be built
#   3 = gitleaks scanned the probe and found nothing -> the config lost the rule
#   4 = python3 is present but building the zip failed
#
# Four codes for four causes, and the contract is spelled out because the first
# version of this split collapsed 2 and 4 into one code while the caller printed
# "python3 missing" for both -- reintroducing, at smaller scale, the exact
# cause-conflation this function was split up to fix.
canary_archive_ok() {
  local rc=0 z="$TMPDIR_SCAN/canary.zip"
  command -v python3 >/dev/null 2>&1 || return 2
  python3 - "$z" "$CANARY_TOKEN" <<'PY' 2>/dev/null || return 4
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("payload.txt", "token " + sys.argv[2])
PY
  gitleaks dir --no-banner --redact --config "$CONFIG" \
    --max-archive-depth "$MAX_ARCHIVE_DEPTH" "$z" >/dev/null 2>&1 || rc=$?
  rm -f "$z"
  # rc=1 means gitleaks found the canary: the traversal path works. rc=0 means it
  # scanned and found nothing, which on a file containing the token means this
  # repo's .gitleaks.toml no longer carries the rule the canary matches -- a
  # config problem, not a version problem, and it must not be reported as one.
  [ "$rc" -eq 1 ] && return 0
  [ "$rc" -eq 0 ] && return 3
  return 1
}

# Match an extension against a list passed BY NAME, e.g. `in_list pdf PDF_EXTS`.
#
# The lists were whitespace-separated strings iterated unquoted, which relied on
# word splitting AND left the words open to pathname expansion -- harmless only
# because no entry happens to contain a glob character. That is a property of the
# current data, not of the code, so an entry like `*.bak` added later would have
# silently matched files in the working directory. Arrays remove the class rather
# than documenting it.
#
# Passed by NAME and indexed via eval, which is the portable option here: `local -n`
# needs bash 4.3 and ${!name[i]} does not do array-element indirection, while this
# has to run under /bin/bash 3.2 on stock macOS. The eval only ever interpolates a
# literal list name from this file, never anything derived from a staged path.
in_list() {
  local needle="$1" listname="$2" i item count
  # Enforce the invariant the comment above only asserted. `listname` reaching
  # eval must be one of the three literals defined at the top of this file, and
  # today it always is — but that is a property of the current call sites, not
  # of the function, and a comment cannot fail. A future caller passing a
  # variable now gets a loud error instead of an eval. Cost is three string
  # comparisons per lookup.
  #
  # exit rather than return: every call site is an `if`/`elif` test, and a
  # non-zero RETURN there reads as "not in this list" — so the file would quietly
  # fall through to the next branch and land in the wrong bucket, with the error
  # scrolling past in hook output. An unknown list name is a programming mistake,
  # not a data condition, and this script's contract is that a bucket it cannot
  # classify is never reported clean.
  # ⚠️ FRAGILE COUPLING, do not break it: this `exit 2` aborts the SCRIPT only because
  # the classification loop is fed by PROCESS SUBSTITUTION (`done < <(git diff …)`), which
  # keeps the loop in the current shell. Rewrite that as a pipe (`git diff … | while …`)
  # and the loop moves to a subshell: `exit 2` then kills only the subshell, the parent
  # continues, and an unclassifiable bucket is silently skipped — precisely the failure
  # the comment above says this prevents. The guard would still LOOK correct while doing
  # nothing. If you ever change how that loop is fed, re-verify this path by planting an
  # unknown list name and confirming the script actually stops.
  case "$listname" in
    ARCHIVE_EXTS|PDF_EXTS|TEXT_ALLOWLISTED_EXTS|OPAQUE_EXTS) ;;
    *) printf '\n✗ in_list: refusing to expand unknown list name: %s\n' "$listname" >&2
       printf '  Add it to the allowlist in in_list() if it is legitimate.\n\n' >&2
       exit 2 ;;
  esac
  eval "count=\${#${listname}[@]}"
  i=0
  while [ "$i" -lt "$count" ]; do
    eval "item=\${${listname}[$i]}"
    [ "$needle" = "$item" ] && return 0
    i=$((i + 1))
  done
  return 1
}

# gitleaks reports its own coverage as "scanned ~N bytes". We read that number
# rather than the input size because for archives the meaningful figure is the
# DECOMPRESSED bytes it actually looked at. Parse failure is treated as UNKNOWN,
# never as clean -- if this log line ever changes shape, the gate must go amber,
# not green. selftest-binary-scan.sh asserts the parse against real output.
parse_scanned_bytes() {
  sed -n 's/.*scanned ~\([0-9][0-9]*\) bytes.*/\1/p' "$1" | tail -n1
}

# $1 = human label for messages, $2 = path to the content to scan
run_gitleaks_stdin() {
  local label="$1" payload="$2" out rc=0 bytes
  out="$TMPDIR_SCAN/out.log"
  gitleaks stdin --no-banner --redact --config "$CONFIG" \
    < "$payload" > "$out" 2>&1 || rc=$?
  bytes="$(parse_scanned_bytes "$out")"

  if [ "$rc" -gt 1 ]; then
    echo "  ✗ $label — gitleaks errored (exit $rc); treating as NOT INSPECTED"
    sed 's/^/      /' "$out"
    unknown+=("$label")
    return
  fi
  if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then
    unknown+=("$label (extractor produced no readable text)")
    return
  fi

  inspected=$((inspected + 1))
  inspected_bytes=$((inspected_bytes + bytes))
  if [ "$rc" -eq 1 ]; then
    leaks=$((leaks + 1))
    echo "  ✗ SECRET in $label"
    sed 's/^/      /' "$out"
  fi
}

# $1 = human label, $2 = path to an archive-shaped file
run_gitleaks_archive() {
  local label="$1" src="$2" probe out rc=0 bytes
  # The .zip extension is the whole trick: it is absent from gitleaks' built-in
  # allowlist, so the file is no longer skipped by path.
  probe="$TMPDIR_SCAN/probe.zip"
  cp "$src" "$probe"
  out="$TMPDIR_SCAN/out.log"
  gitleaks dir --no-banner --redact --config "$CONFIG" \
    --max-archive-depth "$MAX_ARCHIVE_DEPTH" "$probe" > "$out" 2>&1 || rc=$?
  bytes="$(parse_scanned_bytes "$out")"
  rm -f "$probe"

  if [ "$rc" -gt 1 ]; then
    echo "  ✗ $label — gitleaks errored (exit $rc); treating as NOT INSPECTED"
    sed 's/^/      /' "$out"
    unknown+=("$label")
    return
  fi
  if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then
    unknown+=("$label (archive unreadable or empty)")
    return
  fi

  inspected=$((inspected + 1))
  inspected_bytes=$((inspected_bytes + bytes))
  if [ "$rc" -eq 1 ]; then
    leaks=$((leaks + 1))
    echo "  ✗ SECRET in $label"
    # Findings name the temp probe path; point them back at the real file.
    #
    # Both sides are interpolated into a sed s/// expression, so both are escaped
    # first. $probe is ours, but $label is a STAGED FILENAME -- attacker-influenced
    # in any repo that takes contributions, and a name containing `|` or `\` would
    # otherwise corrupt the expression or error out mid-report. Escaping only the
    # delimiter is not enough: `&` in the replacement means "the whole match".
    esc_probe=$(printf '%s' "$probe" | sed 's/[|\\.^$*[]/\\&/g')
    esc_label=$(printf '%s' "$label" | sed 's/[|\\&]/\\&/g')
    sed "s|$esc_probe|$esc_label|g; s/^/      /" "$out"
  fi
}

# ---------------------------------------------------------------------------
# Walk the staged tree. -z because this repo family has filenames with spaces.
# Scan the STAGED BLOB, not the worktree file: they differ whenever a file was
# edited after `git add`, and it is the staged bytes that are about to ship.
# ---------------------------------------------------------------------------
# ENUMERATION FAILS CLOSED. This was inlined as a process substitution, whose exit
# status the loop cannot see: if `git diff --cached` failed -- a corrupt index, a
# broken repo, a bad filter -- the loop simply read nothing, every bucket stayed
# empty, and the script printed "no binary or document files staged" and exited 0.
# An enumeration that did not run is not an empty enumeration.
if ! git diff --cached --name-only -z --no-renames --diff-filter=ACMT \
     > "$TMPDIR_SCAN/staged.list"; then
  echo "  ✗ UNKNOWN: could not enumerate staged files — refusing to report a clean scan" >&2
  exit 1
fi

while IFS= read -r -d '' path; do
  ext="${path##*.}"
  ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
  [ "$ext" = "$path" ] && continue   # no extension -> primary gate's business

  staged="$TMPDIR_SCAN/staged.blob"
  if in_list "$ext" ARCHIVE_EXTS; then
    # Memoized: at most one probe per bucket, per run.
    if [ -z "$archive_canary" ]; then
      probe_rc=0; canary_archive_ok || probe_rc=$?
      case "$probe_rc" in
        0) archive_canary=ok ;;
        2) archive_canary=nopython ;;
        3) archive_canary=norule ;;
        4) archive_canary=buildfail ;;
        *) archive_canary=bad ;;
      esac
    fi
    # Every non-ok state still fails closed as UNKNOWN. Only the stated CAUSE
    # differs, and that is the whole point: each of these sends the developer
    # somewhere different, and the old single message sent two of the three to
    # the wrong place.
    case "$archive_canary" in
      bad)
        unknown+=("$path (gitleaks on PATH cannot traverse archives — needs 8.x)")
        continue ;;
      nopython)
        unknown+=("$path (cannot verify archive scanning: python3 is not installed, so the probe could not be built — gitleaks itself may be fine)")
        continue ;;
      buildfail)
        unknown+=("$path (cannot verify archive scanning: python3 is present but failed to build the probe zip — check the python3 install, not gitleaks)")
        continue ;;
      norule)
        unknown+=("$path (archive probe scanned clean: .gitleaks.toml no longer carries the rule the canary matches — fix the config, not the scanner)")
        continue ;;
    esac
    # A blob that cannot be read is UNKNOWN, not a reason to abort. Under `set -e`
    # a failure here killed the whole scan, so one unreadable file suppressed the
    # verdict on every other staged file -- and the caller saw a non-zero exit with
    # no finding, which reads as "the gate broke" rather than "this was not read".
    if ! git cat-file blob ":$path" > "$staged" 2>/dev/null; then
      unknown+=("$path (staged blob could not be read)")
      continue
    fi
    run_gitleaks_archive "$path" "$staged"
  elif in_list "$ext" PDF_EXTS; then
    if ! command -v pdftotext >/dev/null 2>&1; then
      unknown+=("$path (pdftotext not installed — brew install poppler)")
      continue
    fi
    if [ -z "$pdf_canary" ]; then
      if canary_stdin_ok; then pdf_canary=ok; else pdf_canary=bad; fi
    fi
    if [ "$pdf_canary" = bad ]; then
      unknown+=("$path (gitleaks on PATH has no working \`stdin\` scan — needs 8.x)")
      continue
    fi
    # A blob that cannot be read is UNKNOWN, not a reason to abort. Under `set -e`
    # a failure here killed the whole scan, so one unreadable file suppressed the
    # verdict on every other staged file -- and the caller saw a non-zero exit with
    # no finding, which reads as "the gate broke" rather than "this was not read".
    if ! git cat-file blob ":$path" > "$staged" 2>/dev/null; then
      unknown+=("$path (staged blob could not be read)")
      continue
    fi
    text="$TMPDIR_SCAN/extracted.txt"
    if ! pdftotext -q "$staged" "$text" 2>/dev/null; then
      unknown+=("$path (pdftotext could not parse it)")
      continue
    fi
    # A scanned/image-only PDF still yields one page-separator byte per page, so
    # a raw byte count would climb with page count and read as "inspected" while
    # nothing was actually read. Count NON-WHITESPACE characters instead: that is
    # zero for an image-only document regardless of how long it is.
    if [ "$(tr -d '[:space:]' < "$text" | wc -c | tr -d ' ')" -eq 0 ]; then
      unknown+=("$path (no text layer — image-only or scanned PDF)")
      continue
    fi
    run_gitleaks_stdin "$path" "$text"
  elif in_list "$ext" TEXT_ALLOWLISTED_EXTS; then
    # Already text: no extractor, no canary for a missing tool. It only needs the
    # stdin route, because the path allowlist that hides it is upstream.
    if [ -z "$pdf_canary" ]; then
      if canary_stdin_ok; then pdf_canary=ok; else pdf_canary=bad; fi
    fi
    if [ "$pdf_canary" = bad ]; then
      unknown+=("$path (gitleaks on PATH has no working \`stdin\` scan — needs 8.x)")
      continue
    fi
    # A blob that cannot be read is UNKNOWN, not a reason to abort. Under `set -e`
    # a failure here killed the whole scan, so one unreadable file suppressed the
    # verdict on every other staged file -- and the caller saw a non-zero exit with
    # no finding, which reads as "the gate broke" rather than "this was not read".
    if ! git cat-file blob ":$path" > "$staged" 2>/dev/null; then
      unknown+=("$path (staged blob could not be read)")
      continue
    fi
    run_gitleaks_stdin "$path" "$staged"
  elif in_list "$ext" OPAQUE_EXTS; then
    opaque+=("$path")
  fi
  # Anything else is text: `gitleaks protect --staged` already covered it.
#
# --no-renames is load-bearing, not cosmetic. With rename detection ON, staging a
# renamed file produces an `R` record, which --diff-filter=ACM silently DROPPED --
# so `git mv secret.pdf report.pdf && git commit` sailed past this gate entirely.
# Turning detection off decomposes the rename into D(old) + A(new), and the new
# path is scanned like any other addition. T catches a type change (e.g. a symlink
# replaced by a real file). Verified by selftest-binary-scan.sh case 11.
done < "$TMPDIR_SCAN/staged.list"

# ---------------------------------------------------------------------------
# Report. N-scanned is the point: "nothing was reported" and "the check never
# ran" must never look the same.
# ---------------------------------------------------------------------------
total=$((inspected + ${#opaque[@]} + ${#unknown[@]}))
if [ "$total" -eq 0 ]; then
  echo "  binary scan: no binary or document files staged"
  exit 0
fi

echo "  binary scan: inspected $inspected file(s), $inspected_bytes bytes read"

if [ "${#opaque[@]}" -gt 0 ]; then
  echo "  ⓘ NOT INSPECTED — no text scanner can read these (${#opaque[@]}):"
  printf '      %s\n' "${opaque[@]}"
  echo "      Judge these by hand. This is not a clean result."
fi

if [ "${#unknown[@]}" -gt 0 ]; then
  echo "  ✗ UNKNOWN — these should have been inspectable but were not (${#unknown[@]}):"
  printf '      %s\n' "${unknown[@]}"
  echo "      Fix the extractor, or unstage the file. Refusing to report clean."
  exit 1
fi

[ "$leaks" -gt 0 ] && { echo "  ✗ $leaks file(s) contain secrets — commit blocked"; exit 1; }

exit 0
