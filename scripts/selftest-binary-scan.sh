#!/usr/bin/env bash
# WHAT: Self-test for scan-staged-binaries.sh.
#
# WHY:  This gate exists because a scanner reported "clean" on files it never
#       read. A test that cannot tell those two states apart would reproduce the
#       original defect, so every case below asserts on WHAT WAS INSPECTED, not
#       just on the exit code.
#
# FIXTURES ARE REAL, DELIBERATELY. The PDFs are built with genuinely
#       Flate-compressed content streams (python3 + zlib, both stdlib) and the
#       xlsx is a real zip container. A text file merely NAMED .pdf would pass
#       every check here while proving nothing -- that shortcut is exactly how a
#       fixture ends up encoding the wrong belief.
#
# Run:  scripts/selftest-binary-scan.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/scan-staged-binaries.sh"

# Detach from any inherited git context before the throwaway repos below are created.
#
# WHY: git exports GIT_DIR (an absolute path) into every hook it runs, so the `git init`
# on line ~76 produced a repo that still resolved to the OUTER repository -- inside the
# pre-push hook this failed with "fatal: this operation must be run in a work tree".
# The suite passes standalone and fails only on a real `git push`. SUT above is resolved
# from BASH_SOURCE, not from git, so nothing here needs the ambient repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX GIT_NAMESPACE
# Split so the literal never appears as a matchable token in this file -- a test
# fixture that trips the primary gate would block the commit that adds the test.
SECRET="cr-""0123456789abcdefghijklmnop"

# Assert EVERY tool this suite depends on, not just the obvious one.
#
# WHY all three: a missing tool here does not produce a failure, it produces a
# false pass, which is the defect this whole suite was written against.
#   gitleaks  -- the system under test.
#   python3   -- builds every fixture. Without it `set -e` kills the run inside
#                build_pdf before a single case reports, so the suite dies rather
#                than passing; loud, but it would still be reported as "no output".
#   pdftotext -- what the SUT uses for PDFs. Without it the SUT emits UNKNOWN for
#                doc.pdf, which is the exact string case 10 asserts. Every PDF case
#                then goes green while proving nothing about the version canary
#                they exist to check. This is the dangerous one: silent, and it
#                looks identical to success.
# ...and skipping loudly is still not enough, because `exit 0` IS "pass" to every
# caller. lefthook, CI and `&&` chains all read status, not prose: the message
# scrolled past while the gate went green, which is the same fail-open shape this
# suite exists to detect, sitting in the suite's own preamble.
#
# So: exit NON-ZERO. A missing tool means the suite did not run, and "did not run"
# must never be reportable as "passed". pdftotext is the only genuinely optional
# one, and requiring it here is consistent with scan-staged-binaries.sh, which
# already treats a missing pdftotext as UNKNOWN and blocks the commit rather than
# waving the PDF through.
missing=""
for tool in gitleaks python3 pdftotext; do
  command -v "$tool" >/dev/null 2>&1 || missing="${missing}${tool} "
done
if [ -n "$missing" ]; then
  echo "✗ NOT RUN: missing ${missing}— this suite cannot tell a pass from a no-op without it" >&2
  case "$missing" in *pdftotext*) echo "    pdftotext comes from poppler:  brew install poppler" >&2 ;; esac
  echo "    Reporting failure rather than success: an unrun check is UNKNOWN, not clean." >&2
  exit 1
fi

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ✓ $1"; }
# shellcheck disable=SC2001  # prefixing EVERY line needs sed; ${x//a/b} cannot.
bad()  { fail=$((fail+1)); echo "  ✗ $1"; echo "$2" | sed 's/^/        /'; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- fixture builders (stdlib only, so this runs anywhere) ------------------
build_pdf() {  # build_pdf <out> <text|empty>
  python3 - "$1" "${2-}" <<'PY'
import io, sys, zlib
out, text = sys.argv[1], sys.argv[2]
content = (f"BT /F1 12 Tf 72 720 Td ({text}) Tj ET" if text else "").encode()
stream = zlib.compress(content)           # real deflate -- the whole point
objs = [
    b"<</Type/Catalog/Pages 2 0 R>>",
    b"<</Type/Pages/Kids[3 0 R]/Count 1>>",
    b"<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Contents 4 0 R"
    b"/Resources<</Font<</F1 5 0 R>>>>>>",
    b"<</Length %d/Filter/FlateDecode>>\nstream\n" % len(stream) + stream + b"\nendstream",
    b"<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>",
]
buf = io.BytesIO(); buf.write(b"%PDF-1.4\n"); offs = []
for i, o in enumerate(objs, 1):
    offs.append(buf.tell()); buf.write(b"%d 0 obj " % i + o + b" endobj\n")
xref = buf.tell()
buf.write(b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1))
for o in offs:
    buf.write(b"%010d 00000 n \n" % o)
buf.write(b"trailer <</Size %d/Root 1 0 R>>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref))
open(out, "wb").write(buf.getvalue())
PY
}

build_xlsx() {  # build_xlsx <out> <text>
  python3 - "$1" "$2" <<'PY'
import sys, zipfile
out, text = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("[Content_Types].xml", '<?xml version="1.0"?><Types/>')
    z.writestr("xl/sharedStrings.xml", f'<?xml version="1.0"?><sst><si><t>{text}</t></si></sst>')
PY
}

# --- harness ---------------------------------------------------------------
# Each case runs in a throwaway repo so staging state never leaks between them.
new_repo() {
  local d="$WORK/$1"; mkdir -p "$d"; cd "$d"
  git init -q .

  # Refuse to continue unless `git init` really produced a repo HERE.
  #
  # WHY this is worth six lines: when GIT_DIR is inherited (as it is inside every git
  # hook), `git init .` does not create a new repo -- it RE-INITIALISES the one GIT_DIR
  # points at, from a cwd that is not its work tree, and writes `core.bare = true` into
  # the shared config. On 2026-08-08 that ran during a real `git push` and left the
  # repository and both of its worktrees unusable until core.bare was reset by hand; the
  # `git config user.email t@t.t` below landed in the shared config in the same breath.
  # The unset above prevents it. This assertion is what makes a regression loud and
  # local instead of silent and repo-wide.
  # --absolute-git-dir, NOT --show-toplevel. With an ambient GIT_DIR and no
  # GIT_WORK_TREE, git reports the CWD as the work tree while the object store,
  # index and refs still belong to the other repository -- so --show-toplevel
  # returns exactly what this assertion wants to see and the tripwire never
  # fires. The learnings note in this same PR says so explicitly; this guard
  # was the weaker form it warns against.
  local gd; gd="$(git rev-parse --absolute-git-dir 2>/dev/null || echo '')"
  local root; root="${gd%/.git}"
  if [ "$root" != "$(pwd -P)" ]; then
    echo "FATAL: temp repo resolved to '${root:-<none>}', not '$(pwd -P)'." >&2
    echo "       An ambient GIT_DIR is leaking in. Refusing to touch that repository." >&2
    exit 1
  fi

  git config --local user.email t@t.t; git config --local user.name t
  cp "$SCRIPT_DIR/../.gitleaks.toml" .
  git add .gitleaks.toml
}

run_sut() { set +e; SUT_OUT="$("$SUT" 2>&1)"; SUT_RC=$?; set -e; }

echo "scan-staged-binaries.sh self-test"

# 1. THE CORE CASE: secret inside a really-compressed PDF must be caught.
new_repo c1
build_pdf secret.pdf "API key: $SECRET"
git add secret.pdf; run_sut
if [ "$SUT_RC" -ne 0 ] && grep -q "SECRET in secret.pdf" <<<"$SUT_OUT"; then
  ok "compressed PDF: secret detected, commit blocked"
else bad "compressed PDF: secret NOT detected (rc=$SUT_RC)" "$SUT_OUT"; fi

# 2. REGRESSION GUARD for the approach itself: prove the raw-byte scan this
#    replaces would have MISSED that same file. If this ever starts passing,
#    raw scanning became viable and the pdftotext dependency can be revisited.
#
#    This case reads secret.pdf from the directory case 1 left, and assumes case 1
#    built it. If case 1 is ever reordered or dropped, the redirect fails, the grep
#    fails, and this reports "raw-byte scan now finds it" -- naming the wrong cause
#    entirely. Assert the fixture before drawing any conclusion from its absence.
[ -f secret.pdf ] || { echo "FATAL: case 2 needs the fixture built by case 1" >&2; exit 1; }
if gitleaks stdin --no-banner --redact --config .gitleaks.toml < secret.pdf 2>&1 \
     | grep -q "no leaks found"; then
  ok "raw-byte scan of the same PDF finds nothing (why pdftotext is required)"
else bad "raw-byte scan now finds it — revisit the pdftotext dependency" ""; fi

# 3. Secret inside a real xlsx (zip container) must be caught.
new_repo c3
build_xlsx book.xlsx "token $SECRET"
git add book.xlsx; run_sut
if [ "$SUT_RC" -ne 0 ] && grep -q "SECRET in book.xlsx" <<<"$SUT_OUT"; then
  ok "xlsx: secret inside zip container detected"
else bad "xlsx: secret NOT detected (rc=$SUT_RC)" "$SUT_OUT"; fi

# 4. Clean binaries pass -- and REPORT that bytes were actually read.
new_repo c4
build_pdf clean.pdf "quarterly revenue notes, nothing sensitive"
build_xlsx clean.xlsx "ordinary spreadsheet text"
git add clean.pdf clean.xlsx; run_sut
if [ "$SUT_RC" -eq 0 ] && grep -qE "inspected 2 file\(s\), [1-9][0-9]* bytes read" <<<"$SUT_OUT"; then
  ok "clean binaries pass AND report non-zero bytes read"
else bad "clean binaries: wrong verdict or zero-byte 'pass' (rc=$SUT_RC)" "$SUT_OUT"; fi

# 5. Image-only PDF must read as UNKNOWN, never as clean. This is the exact
#    "scanned ~0 bytes -> no leaks found" failure the whole gate exists to stop.
new_repo c5
build_pdf scanned.pdf ""
git add scanned.pdf; run_sut
if [ "$SUT_RC" -ne 0 ] && grep -q "UNKNOWN" <<<"$SUT_OUT"; then
  ok "image-only PDF reports UNKNOWN instead of clean"
else bad "image-only PDF reported clean (rc=$SUT_RC)" "$SUT_OUT"; fi

# 6. Opaque formats are reported as NOT INSPECTED but do not block.
new_repo c6
printf '\x89PNG\r\n\x1a\n binary junk' > shot.png
git add shot.png; run_sut
if [ "$SUT_RC" -eq 0 ] && grep -q "NOT INSPECTED" <<<"$SUT_OUT"; then
  ok "opaque file reported as NOT INSPECTED, does not block"
else bad "opaque file handling wrong (rc=$SUT_RC)" "$SUT_OUT"; fi

# 7. Filenames with spaces. This repo family really has one ("The High-Paying
#    YouTube Niches Report.pdf"), so word-splitting here would be a live bug.
new_repo c7
build_pdf "My Quarterly Report.pdf" "API key: $SECRET"
git add "My Quarterly Report.pdf"; run_sut
# Assert on "SECRET in <name>", not merely on the name appearing somewhere: the
# name also shows up in the UNKNOWN list, so the looser check passed against a
# deliberately broken build.
if [ "$SUT_RC" -ne 0 ] && grep -q "SECRET in My Quarterly Report.pdf" <<<"$SUT_OUT"; then
  ok "filename with spaces handled"
else bad "filename with spaces mishandled (rc=$SUT_RC)" "$SUT_OUT"; fi

# 8. The STAGED blob is what gets scanned, not the worktree file. Staging a
#    secret and then cleaning the worktree copy must still block the commit --
#    it is the staged bytes that are about to ship.
new_repo c8
build_pdf sneaky.pdf "API key: $SECRET"
git add sneaky.pdf
build_pdf sneaky.pdf "totally innocent now"   # worktree cleaned AFTER staging
run_sut
if [ "$SUT_RC" -ne 0 ] && grep -q "SECRET in sneaky.pdf" <<<"$SUT_OUT"; then
  ok "scans the staged blob, not the worktree copy"
else bad "scanned worktree instead of staged blob (rc=$SUT_RC)" "$SUT_OUT"; fi

# 9. No binaries staged -> fast, explicit no-op.
new_repo c9
printf 'plain text, primary gate handles this\n' > notes.md
git add notes.md; run_sut
if [ "$SUT_RC" -eq 0 ] && grep -q "no binary or document files staged" <<<"$SUT_OUT"; then
  ok "no binaries staged: explicit no-op"
else bad "empty case wrong (rc=$SUT_RC)" "$SUT_OUT"; fi

# 10. The version canary must fail closed. lefthook runs a bare `gitleaks`, so an
#     old binary on PATH is a real scenario (a reviewer's sandbox reported 1.7.3).
#     Simulate it with a stub that answers like a tool lacking these subcommands:
#     the gate must report UNKNOWN, not pass.
new_repo c10
build_pdf doc.pdf "API key: $SECRET"
git add doc.pdf
mkdir -p "$WORK/stub"
printf '#!/bin/sh\necho "unknown command" >&2\nexit 2\n' > "$WORK/stub/gitleaks"
chmod +x "$WORK/stub/gitleaks"
set +e
STUB_OUT="$(PATH="$WORK/stub:$PATH" "$SUT" 2>&1)"; STUB_RC=$?
set -e
# Assert the CAUSE, not just the word UNKNOWN.
#
# "UNKNOWN" alone is emitted by several unrelated paths -- notably a missing
# pdftotext -- so matching it proved only that something went wrong, not that the
# version canary was what caught it. The precondition check above now rules out
# the pdftotext case, and this asserts the specific reason string so the two can
# never be confused again even if that check is later relaxed.
# shellcheck disable=SC2016  # single quotes are deliberate: the backticks are literal
if [ "$STUB_RC" -ne 0 ] && grep -q 'no working `stdin` scan' <<<"$STUB_OUT"; then
  ok "unsupported gitleaks on PATH fails closed as UNKNOWN (named the version canary)"
else bad "unsupported gitleaks did not fail closed via the version canary (rc=$STUB_RC)" "$STUB_OUT"; fi

# 11. A RENAMED binary must still be scanned. This is a regression test for a real
#     hole: the walk used `--diff-filter=ACM`, and a staged rename is an `R` record,
#     so `git mv secret.pdf report.pdf` skipped the gate entirely. Committing a
#     secret required only renaming the file that carried it.
new_repo c11
build_pdf original.pdf "API key: $SECRET"
git add original.pdf
git -c user.email=t@t.t -c user.name=t commit -q -m "chore: add doc" --no-verify
git mv original.pdf renamed.pdf
run_sut
if [ "$SUT_RC" -ne 0 ] && grep -q "SECRET in renamed.pdf" <<<"$SUT_OUT"; then
  ok "renamed binary is still scanned (--diff-filter=ACM regression)"
else bad "renamed binary escaped the scan (rc=$SUT_RC)" "$SUT_OUT"; fi

# 12. A filename containing sed metacharacters must not corrupt the report. The
#     probe->real-path rewrite interpolates BOTH sides into an s/// expression, and
#     a staged filename is attacker-influenced in any repo taking contributions.
#     NOTE ON THE ASSERTIONS: "nonzero exit" and "the name appears" are BOTH true of
#     the broken version too -- it dies mid-report with `sed: bad flag in substitute
#     command`, after the name was already echoed. The first draft of this case passed
#     against a deliberately unescaped build, i.e. proved nothing. What separates them
#     is whether the scan RAN TO COMPLETION: the summary line is printed after the
#     rewrite, so it is absent when sed blows up. Assert that, and that no sed error
#     was emitted at all.
new_repo c12
build_xlsx 'we|rd&name.xlsx' "token $SECRET"
git add 'we|rd&name.xlsx'; run_sut
if [ "$SUT_RC" -ne 0 ] \
   && grep -q 'SECRET in we|rd&name.xlsx' <<<"$SUT_OUT" \
   && grep -q 'binary scan: inspected 1 file' <<<"$SUT_OUT" \
   && ! grep -q 'sed:' <<<"$SUT_OUT"; then
  ok "filename with sed metacharacters reported intact, scan completed"
else bad "sed metacharacters in filename broke the report (rc=$SUT_RC)" "$SUT_OUT"; fi

# 13. SVG is XML text, not an opaque raster. It must be INSPECTED, not filed under
#     "no text scanner can read this" -- it was excluded both here and in
#     .gitleaks.toml, leaving it with no scanning gate at all.
#
#     ASSERT DETECTION, NOT SILENCE. The first draft of this case passed whenever
#     run_sut simply emitted nothing about the file -- which is also what happens if
#     `.svg` returns to the .gitleaks.toml path allowlist. It tested that svg had left
#     one exclusion list while staying blind to the other, i.e. it would have gone
#     green on the very regression it exists to catch. The load-bearing check is that
#     the PRIMARY scanner actually finds the token in a staged .svg.
new_repo c13
printf '<svg xmlns="http://www.w3.org/2000/svg"><desc>token %s</desc></svg>\n' "$SECRET" > diagram.svg
git add diagram.svg
# The PRIMARY gate cannot see this and that is not a bug we can fix locally: the
# built-in allowlist skips .svg upstream, exactly as it does .pdf, so removing svg
# from .gitleaks.toml was necessary and not sufficient. Assert the control that
# actually reaches it -- the binary scanner's stdin route -- and require a POSITIVE
# detection. Asserting "no output about the file" would go green if svg were quietly
# returned to either exclusion list, which is the regression this guards.
set +e
PRIMARY_OUT=$("$SCRIPT_DIR/gitleaks-guard.sh" git --staged --redact --no-banner --verbose 2>&1)
PRIMARY_RC=$?
set -e
run_sut
if [ "$SUT_RC" -ne 0 ] && grep -q "SECRET in diagram.svg" <<<"$SUT_OUT"; then
  ok "svg: secret in a staged .svg is detected (via the stdin route)"
else
  bad "svg NOT detected — it is XML text with no gate (rc=$SUT_RC)" "$SUT_OUT"
fi
# Record the upstream exclusion as a fact rather than an assumption: if this ever
# starts failing, gitleaks changed its built-in allowlist and the extra route can go.
if [ "$PRIMARY_RC" -eq 0 ]; then
  ok "confirmed: the primary gate still cannot see .svg (upstream allowlist)"
else
  bad "primary gate now scans .svg — TEXT_ALLOWLISTED_EXTS may be redundant" "$PRIMARY_OUT"
fi

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
