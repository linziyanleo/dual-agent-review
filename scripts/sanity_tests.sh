#!/usr/bin/env bash
# Framework-free sanity tests for the dual-agent-review skill helpers.
# Runs every test that does NOT require a live herdr session. Intended for
# development; not invoked by SKILL.md itself.
#
# Usage: sanity_tests.sh
# Exit 0 = all green; exit 1 = first failure (with diagnostic to stderr).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_skill_dir.sh"

PASS=0
FAIL=0
CURRENT_TEST=""

pass() { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
die()  { FAIL=$((FAIL+1)); printf '  FAIL: %s — %s\n' "$CURRENT_TEST" "$1" >&2; exit 1; }
step() { CURRENT_TEST="$1"; printf '\n[%s]\n' "$1"; }

WORKDIR="$(mktemp -d -t dar-sanity.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
step "shebang / +x check"
# Per v4 plan F-2: every helper must be executable with a usable shebang.
for f in "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.py; do
  [ -e "$f" ] || continue
  [ -x "$f" ] || die "$(basename "$f") is not executable (chmod +x needed)"
  first="$(head -n1 "$f")"
  case "$f" in
    *.sh) [ "$first" = "#!/usr/bin/env bash"    ] || die "$(basename "$f") first line is '$first', expected '#!/usr/bin/env bash'" ;;
    *.py) [ "$first" = "#!/usr/bin/env python3" ] || die "$(basename "$f") first line is '$first', expected '#!/usr/bin/env python3'" ;;
  esac
done
pass "all scripts have correct shebang and +x"

# ─────────────────────────────────────────────────────────────────────────────
step "render_template.py — special-char values"
TPL="$WORKDIR/tpl.txt"
printf 'A={{A}} B={{B}} C={{C}} D={{D}} E={{E}}\n' > "$TPL"
OUT="$("$SCRIPT_DIR/render_template.py" "$TPL" \
  'A=has spaces' \
  "B=has'apos" \
  'C=has"dquote' \
  'D=has|pipe and\backslash' \
  'E=héllo 🌍')"
EXPECTED='A=has spaces B=has'"'"'apos C=has"dquote D=has|pipe and\backslash E=héllo 🌍'
[ "$OUT" = "$EXPECTED" ] || die "expected: $EXPECTED  got: $OUT"
pass "special chars + unicode rendered correctly"

# Missing template should exit non-zero.
if "$SCRIPT_DIR/render_template.py" "$WORKDIR/nope.txt" 'A=x' 2>/dev/null; then
  die "render_template with missing template should have failed"
fi
pass "missing template -> non-zero"

# ─────────────────────────────────────────────────────────────────────────────
step "render_template.py — _FILE suffix injection + budget"

# Basic file injection
INJECT_TPL="$WORKDIR/inject_tpl.txt"
INJECT_FILE="$WORKDIR/inject_content.txt"
printf 'Before\n{{SPEC_CONTEXT}}\nAfter\n' > "$INJECT_TPL"
printf 'ctx line 1\nctx line 2\n' > "$INJECT_FILE"
OUT="$("$SCRIPT_DIR/render_template.py" "$INJECT_TPL" "SPEC_CONTEXT_FILE=$INJECT_FILE")"
case "$OUT" in *"ctx line 1"*"ctx line 2"*"After"*) pass "file injection replaces placeholder" ;;
                                                   *) die "file injection failed: $OUT" ;;
esac

# Budget truncation at 200 lines
BIG_FILE="$WORKDIR/big.txt"
python3 -c 'for i in range(500): print(f"line {i+1}")' > "$BIG_FILE"
printf '{{SPEC_CONTEXT}}\n' > "$INJECT_TPL"
OUT="$("$SCRIPT_DIR/render_template.py" "$INJECT_TPL" "SPEC_CONTEXT_FILE=$BIG_FILE")"
case "$OUT" in *"line 200"*"truncated at 200 lines"*) pass "budget truncation at 200 lines" ;;
                                                    *) die "budget truncation failed" ;;
esac
case "$OUT" in *"line 201"*) die "line 201 should not appear after truncation" ;; esac
pass "line 201 absent after truncation"

# Missing file -> hard fail (exit 1)
printf '{{SPEC_CONTEXT}}\n' > "$INJECT_TPL"
"$SCRIPT_DIR/render_template.py" "$INJECT_TPL" "SPEC_CONTEXT_FILE=/tmp/nonexistent_dar_file_$$" 2>/dev/null && die "missing injection file should fail" || pass "missing _FILE target -> exit 1"

# Unresolved {{SPEC_CONTEXT}} -> exit 1
printf '{{SPEC_CONTEXT}}\n' > "$INJECT_TPL"
"$SCRIPT_DIR/render_template.py" "$INJECT_TPL" 2>/dev/null && die "unresolved SPEC_CONTEXT should fail" || pass "unresolved {{SPEC_CONTEXT}} -> exit 1"

# ─────────────────────────────────────────────────────────────────────────────
step "render_template.py — vN template renders without SPEC_CONTEXT_FILE"

VN_TPL="$SKILL_DIR/prompts/codex-review-vn.md"
VN_DUMMY_PLAN="$WORKDIR/vn_plan.md"
VN_DUMMY_DISPO="$WORKDIR/vn_dispo.yaml"
VN_DUMMY_DIFF="$WORKDIR/vn.diff"
printf 'dummy plan\n' > "$VN_DUMMY_PLAN"
printf 'dummy dispo\n' > "$VN_DUMMY_DISPO"
printf 'dummy diff\n' > "$VN_DUMMY_DIFF"
VN_OUT="$("$SCRIPT_DIR/render_template.py" "$VN_TPL" \
  "PLAN_PATH=$VN_DUMMY_PLAN" \
  "PREV_DISPOSITION=$VN_DUMMY_DISPO" \
  "DIFF_PATH=$VN_DUMMY_DIFF" \
  "OUTPUT_PATH=$WORKDIR/vn_output.yaml")" || die "vN template render failed without SPEC_CONTEXT_FILE"
pass "vN template renders without SPEC_CONTEXT_FILE"

case "$VN_OUT" in *'{{SPEC_CONTEXT}}'*) die "unresolved {{SPEC_CONTEXT}} in rendered vN" ;; esac
pass "no unresolved {{SPEC_CONTEXT}} token in vN output"

case "$VN_OUT" in *'## Same schema'*) die "repeated schema heading found in vN" ;; esac
pass "no repeated schema heading in vN output"

case "$VN_OUT" in *'## Reminder'*) ;; *) die "missing Reminder section in vN" ;; esac
pass "vN contains Reminder section"

# ─────────────────────────────────────────────────────────────────────────────
step "validate_review_comments.py — 5 broken fixtures + happy path"
fixture_dir="$WORKDIR/findings"
mkdir -p "$fixture_dir"

# (a) empty file
: > "$fixture_dir/empty.yaml"
"$SCRIPT_DIR/validate_review_comments.py" "$fixture_dir/empty.yaml" >/dev/null && die "empty file should fail" || pass "empty file -> fail"

# (b) missing required key (no overall_verdict)
cat > "$fixture_dir/no_verdict.yaml" <<'YAML'
summary: x
review_comments: []
YAML
"$SCRIPT_DIR/validate_review_comments.py" "$fixture_dir/no_verdict.yaml" >/dev/null && die "missing verdict should fail" || pass "missing verdict -> fail"

# (c) invalid enum
cat > "$fixture_dir/bad_severity.yaml" <<'YAML'
overall_verdict: approve
summary: x
review_comments:
  - finding_id: F-1
    severity: catastrophic
    category: correctness
    location: x
    description: x
    suggested_change: x
    rationale: x
YAML
"$SCRIPT_DIR/validate_review_comments.py" "$fixture_dir/bad_severity.yaml" >/dev/null && die "bad severity should fail" || pass "invalid enum -> fail"

# (d) findings not a list
cat > "$fixture_dir/findings_not_list.yaml" <<'YAML'
overall_verdict: approve
summary: x
review_comments: oops
YAML
"$SCRIPT_DIR/validate_review_comments.py" "$fixture_dir/findings_not_list.yaml" >/dev/null && die "non-list review_comments should fail" || pass "review_comments non-list -> fail"

# (e) duplicate finding_id
cat > "$fixture_dir/dup_id.yaml" <<'YAML'
overall_verdict: approve
summary: x
review_comments:
  - {finding_id: F-1, severity: high, category: correctness, location: x, description: x, suggested_change: x, rationale: x}
  - {finding_id: F-1, severity: low,  category: correctness, location: x, description: x, suggested_change: x, rationale: x}
YAML
OUT="$("$SCRIPT_DIR/validate_review_comments.py" "$fixture_dir/dup_id.yaml" 2>&1)" && die "dup id should fail" || true
case "$OUT" in *"duplicate finding_id"*"F-1"*) pass "dup finding_id -> fail with descriptive message" ;;
                                          *) die "dup_id error message lacks 'duplicate finding_id F-1': $OUT" ;;
esac

# happy path
cat > "$fixture_dir/happy.yaml" <<'YAML'
overall_verdict: request_changes
summary: a real summary
review_comments:
  - {finding_id: F-1, severity: high, category: security, location: foo:1, description: d, suggested_change: c, rationale: r}
  - {finding_id: F-2, severity: low,  category: testing,  location: foo:2, description: d, suggested_change: c, rationale: r}
YAML
"$SCRIPT_DIR/validate_review_comments.py" "$fixture_dir/happy.yaml" || die "happy path should pass"
pass "happy path -> 0"

# (f) cross-field: approve + any non-empty findings (high/medium/low/nit) must fail.
# Per prompts/codex-review-v1.md: approve means review_comments: [] — don't invent nits to fill space.
cat > "$fixture_dir/approve_with_high.yaml" <<'YAML'
overall_verdict: approve
summary: bogus
review_comments:
  - {finding_id: F-1, severity: high, category: correctness, location: x, description: d, suggested_change: c, rationale: r}
YAML
OUT="$("$SCRIPT_DIR/validate_review_comments.py" "$fixture_dir/approve_with_high.yaml" 2>&1)" && die "approve+high should fail" || true
case "$OUT" in *"requires review_comments: []"*) pass "approve+high -> fail with 'requires review_comments: []' message" ;;
                                        *) die "approve+high message should say 'requires review_comments: []': $OUT" ;;
esac

# (g) approve + low-only must also fail (the prompt forbids approve with ANY findings).
cat > "$fixture_dir/approve_with_low.yaml" <<'YAML'
overall_verdict: approve
summary: looks fine but here's a nit
review_comments:
  - {finding_id: F-1, severity: low, category: maintainability, location: x, description: d, suggested_change: c, rationale: r}
YAML
OUT="$("$SCRIPT_DIR/validate_review_comments.py" "$fixture_dir/approve_with_low.yaml" 2>&1)" && die "approve+low should fail" || true
case "$OUT" in *"requires review_comments: []"*) pass "approve+low -> fail (no nit smuggling past approve)" ;;
                                        *) die "approve+low message should say 'requires review_comments: []': $OUT" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
step "validate_dispositions.py — 9 broken fixtures + happy path"
dd="$WORKDIR/dispo"
mkdir -p "$dd"

# Use the happy findings file from above for all positive checks.
HAPPY_FINDINGS="$fixture_dir/happy.yaml"

# (0) gate: upstream findings invalid (use empty findings file)
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_review_comments: 0
dispositions: []
YAML
"$SCRIPT_DIR/validate_dispositions.py" "$fixture_dir/empty.yaml" "$dd/v1.dispositions.yaml" >/dev/null && die "upstream invalid should fail" || pass "upstream findings invalid -> fail"

# (1) missing disposition entry for F-2
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_review_comments: 1
dispositions:
  - {finding_id: F-1, disposition: rejected, reason: nope}
YAML
"$SCRIPT_DIR/validate_dispositions.py" "$HAPPY_FINDINGS" "$dd/v1.dispositions.yaml" >/dev/null && die "missing disposition should fail" || pass "missing disposition -> fail"

# (2) invalid disposition enum
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_review_comments: 2
dispositions:
  - {finding_id: F-1, disposition: ignored, reason: nope}
  - {finding_id: F-2, disposition: rejected, reason: nope}
YAML
"$SCRIPT_DIR/validate_dispositions.py" "$HAPPY_FINDINGS" "$dd/v1.dispositions.yaml" >/dev/null && die "invalid enum should fail" || pass "invalid disposition enum -> fail"

# (3) rejected without reason
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_review_comments: 2
dispositions:
  - {finding_id: F-1, disposition: rejected, reason: ""}
  - {finding_id: F-2, disposition: rejected, reason: nope}
YAML
"$SCRIPT_DIR/validate_dispositions.py" "$HAPPY_FINDINGS" "$dd/v1.dispositions.yaml" >/dev/null && die "rejected w/o reason should fail" || pass "rejected w/o reason -> fail"

# (4) extra finding_id in dispositions (set inequality)
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_review_comments: 3
dispositions:
  - {finding_id: F-1, disposition: rejected, reason: nope}
  - {finding_id: F-2, disposition: rejected, reason: nope}
  - {finding_id: F-9, disposition: rejected, reason: nope}
YAML
"$SCRIPT_DIR/validate_dispositions.py" "$HAPPY_FINDINGS" "$dd/v1.dispositions.yaml" >/dev/null && die "extra finding_id should fail" || pass "extra finding_id -> fail"

# (5) duplicate finding_id in dispositions
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_review_comments: 2
dispositions:
  - {finding_id: F-1, disposition: rejected, reason: nope}
  - {finding_id: F-1, disposition: rejected, reason: nope}
YAML
"$SCRIPT_DIR/validate_dispositions.py" "$HAPPY_FINDINGS" "$dd/v1.dispositions.yaml" >/dev/null && die "dup finding_id should fail" || pass "dup finding_id -> fail"

# (6) total_review_comments mismatch
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_review_comments: 99
dispositions:
  - {finding_id: F-1, disposition: rejected, reason: nope}
  - {finding_id: F-2, disposition: rejected, reason: nope}
YAML
"$SCRIPT_DIR/validate_dispositions.py" "$HAPPY_FINDINGS" "$dd/v1.dispositions.yaml" >/dev/null && die "total_review_comments mismatch should fail" || pass "total_review_comments mismatch -> fail"

# (7) plan_version_reviewed doesn't match filename
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v9
total_review_comments: 2
dispositions:
  - {finding_id: F-1, disposition: rejected, reason: nope}
  - {finding_id: F-2, disposition: rejected, reason: nope}
YAML
"$SCRIPT_DIR/validate_dispositions.py" "$HAPPY_FINDINGS" "$dd/v1.dispositions.yaml" >/dev/null && die "version mismatch should fail" || pass "plan_version_reviewed mismatch -> fail"

# (7b) plan_version_reviewed as bare integer (LLM writes 1 instead of "v1") should pass
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: 1
total_review_comments: 2
dispositions:
  - {finding_id: F-1, disposition: incorporated, plan_change_summary: did the thing}
  - {finding_id: F-2, disposition: rejected, reason: not relevant}
YAML
"$SCRIPT_DIR/validate_dispositions.py" "$HAPPY_FINDINGS" "$dd/v1.dispositions.yaml" || die "bare int plan_version_reviewed should be normalized"
pass "plan_version_reviewed: 1 (int) normalized to v1 -> pass"

# (8) incorporated without plan_change_summary
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_review_comments: 2
dispositions:
  - {finding_id: F-1, disposition: incorporated}
  - {finding_id: F-2, disposition: rejected, reason: nope}
YAML
"$SCRIPT_DIR/validate_dispositions.py" "$HAPPY_FINDINGS" "$dd/v1.dispositions.yaml" >/dev/null && die "incorporated w/o summary should fail" || pass "incorporated w/o plan_change_summary -> fail"

# happy
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_review_comments: 2
dispositions:
  - {finding_id: F-1, disposition: incorporated, plan_change_summary: did the thing}
  - {finding_id: F-2, disposition: rejected,     reason: not relevant}
YAML
"$SCRIPT_DIR/validate_dispositions.py" "$HAPPY_FINDINGS" "$dd/v1.dispositions.yaml" || die "happy dispositions should pass"
pass "happy dispositions -> 0"

# (9a) high deferred is rejected outright (even with reason + follow_up).
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_review_comments: 2
dispositions:
  - {finding_id: F-1, disposition: deferred, reason: "needs spec", follow_up: "ticket PROD-42"}
  - {finding_id: F-2, disposition: rejected, reason: nope}
YAML
OUT="$("$SCRIPT_DIR/validate_dispositions.py" "$HAPPY_FINDINGS" "$dd/v1.dispositions.yaml" 2>&1)" && die "high deferred should fail" || true
case "$OUT" in *"not allowed for high/medium"*) pass "high deferred -> fail (high/medium can't be deferred at all)" ;;
                                              *) die "high-deferred error message should mention high/medium ban: $OUT" ;;
esac

# (9b) medium deferred is rejected outright as well.
# Use a fixtures file that has a medium-severity finding to force this branch.
MED_FINDINGS="$fixture_dir/medium.yaml"
cat > "$MED_FINDINGS" <<'YAML'
overall_verdict: request_changes
summary: x
review_comments:
  - {finding_id: F-1, severity: medium, category: correctness, location: x, description: d, suggested_change: c, rationale: r}
YAML
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_review_comments: 1
dispositions:
  - {finding_id: F-1, disposition: deferred, reason: "later", follow_up: "ticket FOO-1"}
YAML
OUT="$("$SCRIPT_DIR/validate_dispositions.py" "$MED_FINDINGS" "$dd/v1.dispositions.yaml" 2>&1)" && die "medium deferred should fail" || true
case "$OUT" in *"not allowed for high/medium"*) pass "medium deferred -> fail" ;;
                                              *) die "medium-deferred error should mention high/medium ban: $OUT" ;;
esac

# (9c) low deferred remains lightweight (no extra fields required).
LOW_FINDINGS="$fixture_dir/low_only.yaml"
cat > "$LOW_FINDINGS" <<'YAML'
overall_verdict: request_changes
summary: x
review_comments:
  - {finding_id: F-1, severity: low, category: maintainability, location: x, description: d, suggested_change: c, rationale: r}
YAML
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_review_comments: 1
dispositions:
  - {finding_id: F-1, disposition: deferred}
YAML
"$SCRIPT_DIR/validate_dispositions.py" "$LOW_FINDINGS" "$dd/v1.dispositions.yaml" || die "low deferred should pass without extras"
pass "low deferred without reason/follow_up -> 0 (lightweight escape hatch)"

# ─────────────────────────────────────────────────────────────────────────────
step "check_convergence.py — 4 enums under set -e"
cv="$WORKDIR/conv"
mkdir -p "$cv"

# CONVERGED_APPROVE on v1.
cat > "$cv/v1.review-comments.yaml" <<'YAML'
overall_verdict: approve
summary: ok
review_comments: []
YAML
OUT="$("$SCRIPT_DIR/check_convergence.py" "$cv" 1)"
[ "$OUT" = "CONVERGED_APPROVE" ] || die "expected CONVERGED_APPROVE, got $OUT"
pass "v1 approve -> CONVERGED_APPROVE (exit 0)"

# CONTINUE on v1 with request_changes + medium finding.
cat > "$cv/v1.review-comments.yaml" <<'YAML'
overall_verdict: request_changes
summary: x
review_comments:
  - {finding_id: F-1, severity: medium, category: correctness, location: x, description: d, suggested_change: c, rationale: r}
YAML
OUT="$("$SCRIPT_DIR/check_convergence.py" "$cv" 1)"
[ "$OUT" = "CONTINUE" ] || die "expected CONTINUE, got $OUT"
pass "v1 request_changes w/ medium -> CONTINUE (exit 0)"

# CONVERGED_NO_BLOCKERS on v2 when v1 + v2 both have only low/nit (with dispositions written).
cat > "$cv/v1.review-comments.yaml" <<'YAML'
overall_verdict: request_changes
summary: x
review_comments:
  - {finding_id: F-1, severity: low, category: correctness, location: x, description: d, suggested_change: c, rationale: r}
YAML
cat > "$cv/v2.review-comments.yaml" <<'YAML'
overall_verdict: request_changes
summary: x
review_comments:
  - {finding_id: F-1, severity: nit, category: correctness, location: x, description: d, suggested_change: c, rationale: r}
YAML
cat > "$cv/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_review_comments: 1
dispositions:
  - {finding_id: F-1, disposition: deferred}
YAML
cat > "$cv/v2.dispositions.yaml" <<'YAML'
plan_version_reviewed: v2
total_review_comments: 1
dispositions:
  - {finding_id: F-1, disposition: deferred}
YAML
OUT="$("$SCRIPT_DIR/check_convergence.py" "$cv" 2)"
[ "$OUT" = "CONVERGED_NO_BLOCKERS" ] || die "expected CONVERGED_NO_BLOCKERS, got $OUT"
pass "v1+v2 no blockers + dispositions written -> CONVERGED_NO_BLOCKERS (exit 0)"
rm -f "$cv"/v?.dispositions.yaml

# MAX_ROUNDS_REACHED at round 5 with still-pending medium (with dispositions written every round).
for n in 1 2 3 4 5; do
  cat > "$cv/v${n}.review-comments.yaml" <<YAML
overall_verdict: request_changes
summary: x
review_comments:
  - {finding_id: F-1, severity: medium, category: correctness, location: x, description: d, suggested_change: c, rationale: r}
YAML
  cat > "$cv/v${n}.dispositions.yaml" <<YAML
plan_version_reviewed: v${n}
total_review_comments: 1
dispositions:
  - {finding_id: F-1, disposition: rejected, reason: "tracked in external ticket FOO-${n}"}
YAML
done
OUT="$("$SCRIPT_DIR/check_convergence.py" "$cv" 5)"
[ "$OUT" = "MAX_ROUNDS_REACHED" ] || die "expected MAX_ROUNDS_REACHED, got $OUT"
pass "round 5 unresolved + dispositions written -> MAX_ROUNDS_REACHED (exit 0)"
rm -f "$cv"/v?.dispositions.yaml

# block verdict with only low/nit findings must still block convergence
rm -f "$cv/v1.review-comments.yaml" "$cv/v2.review-comments.yaml"
cat > "$cv/v1.review-comments.yaml" <<'YAML'
overall_verdict: request_changes
summary: x
review_comments:
  - {finding_id: F-1, severity: low, category: correctness, location: x, description: d, suggested_change: c, rationale: r}
YAML
cat > "$cv/v2.review-comments.yaml" <<'YAML'
overall_verdict: block
summary: pipeline broken
review_comments:
  - {finding_id: F-1, severity: low, category: correctness, location: x, description: d, suggested_change: c, rationale: r}
YAML
OUT="$("$SCRIPT_DIR/check_convergence.py" "$cv" 2)"
[ "$OUT" = "CONTINUE" ] || die "expected CONTINUE (block beats low), got $OUT"
pass "block verdict + only-low -> CONTINUE (block is always a blocker)"

# Workflow gate (v3 F-1): findings non-empty but v(N).dispositions.yaml missing
# must return CONTINUE — the loop cannot finalize without recording dispositions
# for the current round, even for low-only request_changes.
rm -f "$cv"/v?.review-comments.yaml "$cv"/v?.dispositions.yaml
cat > "$cv/v1.review-comments.yaml" <<'YAML'
overall_verdict: request_changes
summary: x
review_comments:
  - {finding_id: F-1, severity: low, category: style, location: x, description: d, suggested_change: c, rationale: r}
YAML
cat > "$cv/v2.review-comments.yaml" <<'YAML'
overall_verdict: request_changes
summary: x
review_comments:
  - {finding_id: F-1, severity: low, category: style, location: x, description: d, suggested_change: c, rationale: r}
YAML
# v2.dispositions.yaml deliberately absent.
OUT="$("$SCRIPT_DIR/check_convergence.py" "$cv" 2)"
[ "$OUT" = "CONTINUE" ] || die "expected CONTINUE (v2.dispositions missing), got $OUT"
pass "request_changes + low-only + missing v(N).dispositions -> CONTINUE (workflow gate)"

# Same setup but with v2.dispositions present should now hit rule B (no blockers across v1+v2).
cat > "$cv/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_review_comments: 1
dispositions:
  - {finding_id: F-1, disposition: deferred}
YAML
cat > "$cv/v2.dispositions.yaml" <<'YAML'
plan_version_reviewed: v2
total_review_comments: 1
dispositions:
  - {finding_id: F-1, disposition: deferred}
YAML
OUT="$("$SCRIPT_DIR/check_convergence.py" "$cv" 2)"
[ "$OUT" = "CONVERGED_NO_BLOCKERS" ] || die "expected CONVERGED_NO_BLOCKERS with dispositions written, got $OUT"
pass "low-only + v(N).dispositions written -> CONVERGED_NO_BLOCKERS (gate releases)"
rm -f "$cv"/v?.review-comments.yaml "$cv"/v?.dispositions.yaml

# ─────────────────────────────────────────────────────────────────────────────
step "append_rejected_section.py — cross-3-round idempotent"
ar="$WORKDIR/append"
mkdir -p "$ar"
# Build minimal findings + dispositions for v1/v2/v3 with mixed rejected.
for n in 1 2 3; do
  cat > "$ar/v${n}.review-comments.yaml" <<YAML
overall_verdict: request_changes
summary: x
review_comments:
  - {finding_id: F-${n}A, severity: medium, category: correctness, location: x, description: "round ${n} A desc", suggested_change: c, rationale: r}
  - {finding_id: F-${n}B, severity: low,    category: scope,       location: x, description: "round ${n} B desc", suggested_change: c, rationale: r}
YAML
done
cat > "$ar/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_review_comments: 2
dispositions:
  - {finding_id: F-1A, disposition: incorporated, plan_change_summary: ok}
  - {finding_id: F-1B, disposition: rejected,     reason: not relevant in v1}
YAML
cat > "$ar/v2.dispositions.yaml" <<'YAML'
plan_version_reviewed: v2
total_review_comments: 2
dispositions:
  - {finding_id: F-2A, disposition: rejected, reason: out of scope}
  - {finding_id: F-2B, disposition: deferred}
YAML
cat > "$ar/v3.dispositions.yaml" <<'YAML'
plan_version_reviewed: v3
total_review_comments: 2
dispositions:
  - {finding_id: F-3A, disposition: incorporated, plan_change_summary: ok}
  - {finding_id: F-3B, disposition: rejected,     reason: stylistic}
YAML
cat > "$ar/plan.md" <<'MD'
# Plan v3

## Context
some content
MD

"$SCRIPT_DIR/append_rejected_section.py" "$ar" "$ar/plan.md" >/dev/null
FIRST="$(cat "$ar/plan.md")"
case "$FIRST" in *"From v1 review"*"From v2 review"*"From v3 review"*) ;;
                                                                       *) die "expected v1/v2/v3 groups all present, got: $FIRST" ;;
esac
case "$FIRST" in *"F-1B"*"F-2A"*"F-3B"*) ;;
                                       *) die "expected F-1B, F-2A, F-3B in rejected section, got: $FIRST" ;;
esac
# F-2B is deferred; assert it is NOT inside the rejected section span (header to next '## ').
REJECTED_SPAN="$(awk '/^## Rejected suggestions/{flag=1;next} /^## /{flag=0} flag' "$ar/plan.md")"
case "$REJECTED_SPAN" in *"F-2B"*) die "F-2B is deferred, must NOT appear in rejected section span" ;; esac

"$SCRIPT_DIR/append_rejected_section.py" "$ar" "$ar/plan.md" >/dev/null
SECOND="$(cat "$ar/plan.md")"
[ "$FIRST" = "$SECOND" ] || die "second run was not idempotent"
pass "cross-3-round aggregation + idempotent"

# Both rejected AND deferred sections must be present; F-2B (deferred low) lives in the deferred section.
case "$FIRST" in *"## Rejected suggestions (from review)"*"## Deferred suggestions (from review)"*) ;;
                                                                                                  *) die "expected both rejected and deferred section headers" ;;
esac
case "$FIRST" in *"## Deferred suggestions (from review)"*"F-2B"*) pass "F-2B appears in deferred section" ;;
                                                                 *) die "F-2B (deferred low) missing from deferred section" ;;
esac

# Cross-3-round with a HIGH deferred carrying reason + follow_up — must render both fields.
arh="$WORKDIR/append_high_defer"
mkdir -p "$arh"
cat > "$arh/v1.review-comments.yaml" <<'YAML'
overall_verdict: request_changes
summary: x
review_comments:
  - {finding_id: F-1, severity: high, category: correctness, location: x, description: "load-bearing bug", suggested_change: c, rationale: r}
YAML
cat > "$arh/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_review_comments: 1
dispositions:
  - {finding_id: F-1, disposition: deferred, reason: "needs DB migration first", follow_up: "ticket OPS-77"}
YAML
printf '# Plan\n\n## Context\nstub\n' > "$arh/plan.md"
"$SCRIPT_DIR/append_rejected_section.py" "$arh" "$arh/plan.md" >/dev/null
HIGH="$(cat "$arh/plan.md")"
case "$HIGH" in *"## Deferred suggestions (from review)"*"F-1"*"needs DB migration first"*"OPS-77"*) ;;
                                                                                                  *) die "deferred section missing reason or follow_up for high deferred: $HIGH" ;;
esac
pass "high-deferred with reason+follow_up renders both fields in deferred section"

# ─────────────────────────────────────────────────────────────────────────────
step "append_rejected_section.py — backtick-wrapped header literal must NOT be eaten (F-5)"
arb="$WORKDIR/append_backtick_literal"
mkdir -p "$arb"
cat > "$arb/v1.review-comments.yaml" <<'YAML'
overall_verdict: request_changes
summary: x
review_comments:
  - {finding_id: F-1, severity: low, category: style, location: x, description: "minor", suggested_change: c, rationale: r}
YAML
cat > "$arb/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_review_comments: 1
dispositions:
  - {finding_id: F-1, disposition: rejected, reason: stylistic-only}
YAML
# Plan body mentions the header literal inside a backtick code span — must NOT be matched.
# The marker text after the literal verifies that surrounding body is not eaten by the regex.
cat > "$arb/plan.md" <<'MD'
# Plan v2

## Proposed approach
- script docs reference `## Rejected suggestions (from review)` as a string MARKER_TOKEN_DO_NOT_EAT and continues here.

## Affected files
- one
MD
"$SCRIPT_DIR/append_rejected_section.py" "$arb" "$arb/plan.md" >/dev/null
BT_OUT="$(cat "$arb/plan.md")"
case "$BT_OUT" in *"MARKER_TOKEN_DO_NOT_EAT"*) ;;
                                              *) die "F-5 regression: body around backtick-wrapped header literal was eaten" ;;
esac
case "$BT_OUT" in *"## Affected files"*"one"*) ;;
                                              *) die "F-5 regression: Affected files section was eaten/garbled" ;;
esac
# A real rejected section must still be appended at the end (since no preceding real header existed).
case "$BT_OUT" in *"## Rejected suggestions (from review)"*"F-1"*"stylistic-only"*) ;;
                                                                                  *) die "F-5: expected real rejected section appended with F-1 reason" ;;
esac
pass "backtick-wrapped header literal preserved; real section appended at end"

# ─────────────────────────────────────────────────────────────────────────────
step "append_rejected_section.py — header inside fenced code block must NOT be eaten (F-3 from v2 review)"
arf="$WORKDIR/append_fence_literal"
mkdir -p "$arf"
cat > "$arf/v1.review-comments.yaml" <<'YAML'
overall_verdict: request_changes
summary: x
review_comments:
  - {finding_id: F-1, severity: low, category: style, location: x, description: "minor", suggested_change: c, rationale: r}
YAML
cat > "$arf/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_review_comments: 1
dispositions:
  - {finding_id: F-1, disposition: rejected, reason: stylistic-only}
YAML
# Plan body that DOCUMENTS the section format inside a fenced code block.
# The header line inside ``` must be treated as example text, not a real section.
# FENCE_INNER_MARKER verifies the fenced content survives untouched.
cat > "$arf/plan.md" <<'MD'
# Plan v2

## Proposed approach
This skill generates a section like:

```
## Rejected suggestions (from review)

### From v1 review
FENCE_INNER_MARKER_DO_NOT_EAT
- **F-X** — example
```

## Affected files
- two
MD
"$SCRIPT_DIR/append_rejected_section.py" "$arf" "$arf/plan.md" >/dev/null
FN_OUT="$(cat "$arf/plan.md")"
case "$FN_OUT" in *"FENCE_INNER_MARKER_DO_NOT_EAT"*) ;;
                                                   *) die "F-3: header inside fence was treated as managed; fenced example was eaten" ;;
esac
case "$FN_OUT" in *"## Affected files"*"two"*) ;;
                                             *) die "F-3: Affected files section was eaten when fence-scan skipped" ;;
esac
case "$FN_OUT" in *"## Rejected suggestions (from review)"*"F-1"*"stylistic-only"*) ;;
                                                                                  *) die "F-3: expected real rejected section appended at end with F-1 reason" ;;
esac
# Idempotency in the presence of a fenced example: second run must produce identical output.
FIRST="$FN_OUT"
"$SCRIPT_DIR/append_rejected_section.py" "$arf" "$arf/plan.md" >/dev/null
SECOND="$(cat "$arf/plan.md")"
[ "$FIRST" = "$SECOND" ] || die "F-3: second run not idempotent in the presence of fenced example"
pass "fenced header literal preserved; managed section only matches outside fences; idempotent"

# ─────────────────────────────────────────────────────────────────────────────
step "cleanup_stale_panes.sh — TTL force-close path via fake herdr shim"
cleanup_root="$WORKDIR/cleanup/.specanchor/tasks"
mkdir -p "$cleanup_root/agent_review_current"
mkdir -p "$cleanup_root/agent_review_old"

# Current session metadata (does nothing; just to satisfy the loop's exclusion).
cat > "$cleanup_root/agent_review_current/session.meta" <<'META'
MAIN_TERMINAL=term_main
WORKSPACE_ID=ws_main
META

# Old session: owned pane with terminal_id matching what fake herdr will return.
cat > "$cleanup_root/agent_review_old/session.meta" <<'META'
MAIN_TERMINAL=term_main
WORKSPACE_ID=ws_main
META
printf 'old_pane\n'     > "$cleanup_root/agent_review_old/.codex-pane-id"
printf 'old_terminal\n' > "$cleanup_root/agent_review_old/.codex-terminal-id"

# Build a fake `herdr` on PATH. shim writes pane close ids into SENTINEL.
SHIM_DIR="$WORKDIR/shim"
mkdir -p "$SHIM_DIR"
SENTINEL="$WORKDIR/shim_closed.log"
: > "$SENTINEL"

cat > "$SHIM_DIR/herdr" <<SHIM
#!/usr/bin/env bash
case "\$1 \$2" in
  "pane get")
    printf '{"result":{"pane":{"terminal_id":"old_terminal","agent_status":"%s"}}}\n' "\${SHIM_PANE_STATUS:-working}"
    ;;
  "pane close")
    printf '%s\n' "\$3" >> "$SENTINEL"
    ;;
  *)
    : ;;
esac
SHIM
chmod +x "$SHIM_DIR/herdr"

# Sub-test 1: mtime > TTL with status=working -> force close, sentinel records call.
touch -t 202001010000 "$cleanup_root/agent_review_old"   # very old; well past any TTL
SHIM_PANE_STATUS=working DAR_PANE_TTL_SECS=7200 PATH="$SHIM_DIR:$PATH" \
  "$SCRIPT_DIR/cleanup_stale_panes.sh" "$cleanup_root/agent_review_current" term_main ws_main
grep -qx 'old_pane' "$SENTINEL" || die "expected fake herdr to receive 'pane close old_pane', got: $(cat "$SENTINEL")"
grep -q 'AUTO_CLOSED_STALE_TTL' "$cleanup_root/agent_review_old/session.log" || die "TTL close should log AUTO_CLOSED_STALE_TTL"
pass "TTL expired + working pane -> force-close + sentinel recorded + AUTO_CLOSED_STALE_TTL logged"

# Sub-test 2: mtime fresh (< TTL) with status=working -> must NOT close.
mkdir -p "$cleanup_root/agent_review_fresh"
cat > "$cleanup_root/agent_review_fresh/session.meta" <<'META'
MAIN_TERMINAL=term_main
WORKSPACE_ID=ws_main
META
printf 'fresh_pane\n'     > "$cleanup_root/agent_review_fresh/.codex-pane-id"
printf 'fresh_terminal\n' > "$cleanup_root/agent_review_fresh/.codex-terminal-id"

# rewrite shim to return terminal_id=fresh_terminal so ownership check passes
cat > "$SHIM_DIR/herdr" <<SHIM
#!/usr/bin/env bash
case "\$1 \$2" in
  "pane get")
    printf '{"result":{"pane":{"terminal_id":"fresh_terminal","agent_status":"%s"}}}\n' "\${SHIM_PANE_STATUS:-working}"
    ;;
  "pane close")
    printf '%s\n' "\$3" >> "$SENTINEL"
    ;;
  *)
    : ;;
esac
SHIM
: > "$SENTINEL"
SHIM_PANE_STATUS=working DAR_PANE_TTL_SECS=7200 PATH="$SHIM_DIR:$PATH" \
  "$SCRIPT_DIR/cleanup_stale_panes.sh" "$cleanup_root/agent_review_current" term_main ws_main
if grep -qx 'fresh_pane' "$SENTINEL"; then
  die "fresh-mtime working pane must NOT be force-closed; sentinel: $(cat "$SENTINEL")"
fi
pass "fresh mtime + working pane -> no close (TTL not exceeded)"

# ─────────────────────────────────────────────────────────────────────────────
step "init_session.sh — hard .specanchor/tasks path + agent_review_ prefix + SA_SKILL_DIR"
# Hermetic: build a fake `herdr` on PATH that returns the JSON init_session needs.
case_a_shim="$WORKDIR/case_a_shim"
mkdir -p "$case_a_shim"
cat > "$case_a_shim/herdr" <<'SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "pane get")  printf '{"result":{"pane":{"terminal_id":"term_a","workspace_id":"ws_a","tab_id":"tab_a"}}}\n' ;;
  "pane list") printf '[]\n' ;;
  *) : ;;
esac
SHIM
chmod +x "$case_a_shim/herdr"

# init_session always writes to .specanchor/tasks/ with agent_review_ prefix
mkdir -p "$WORKDIR/repo-specanchor/.specanchor"
SR="$(cd "$WORKDIR/repo-specanchor" && \
  HERDR_PANE_ID=p_a SA_SKILL_DIR=/tmp/fake-sa PATH="$case_a_shim:$PATH" "$SCRIPT_DIR/init_session.sh")"
case "$SR" in
  "$WORKDIR/repo-specanchor/.specanchor/tasks/agent_review_"*) ;;
  *) die "expected .specanchor/tasks/agent_review_* path, got $SR" ;;
esac
grep -q "SESSIONS_ROOT=" "$SR/session.env" \
  || die "session.env missing SESSIONS_ROOT"
grep -q "SA_SKILL_DIR=" "$SR/session.env" \
  || die "session.env missing SA_SKILL_DIR"
grep -q "SA_SKILL_DIR='/tmp/fake-sa'" "$SR/session.env" \
  || die "session.env SA_SKILL_DIR value wrong: $(grep SA_SKILL_DIR "$SR/session.env")"
pass "init_session -> .specanchor/tasks/agent_review_* + SA_SKILL_DIR in session.env"

# REVIEW_MODE defaults to 'codex' when unset
grep -q "REVIEW_MODE='codex'" "$SR/session.env" \
  || die "session.env REVIEW_MODE should default to 'codex', got: $(grep REVIEW_MODE "$SR/session.env" || echo MISSING)"
grep -q "REVIEW_MODE=codex" "$SR/session.meta" \
  || die "session.meta missing REVIEW_MODE=codex"
pass "init_session default REVIEW_MODE=codex in meta+env"

# REVIEW_MODE=subagent is persisted when set
SR_SUB="$(cd "$WORKDIR/repo-specanchor" && \
  HERDR_PANE_ID=p_a SA_SKILL_DIR=/tmp/fake-sa REVIEW_MODE=subagent \
  PATH="$case_a_shim:$PATH" "$SCRIPT_DIR/init_session.sh")"
grep -q "REVIEW_MODE='subagent'" "$SR_SUB/session.env" \
  || die "session.env should persist REVIEW_MODE='subagent', got: $(grep REVIEW_MODE "$SR_SUB/session.env" || echo MISSING)"
grep -q "REVIEW_MODE=subagent" "$SR_SUB/session.meta" \
  || die "session.meta should persist REVIEW_MODE=subagent"
pass "init_session persists REVIEW_MODE=subagent in meta+env"

# ─────────────────────────────────────────────────────────────────────────────
step "cleanup_stale_panes.sh — agent_review_* filter (only scans matching dirs)"
case_d_repo="$WORKDIR/case_d_repo"
case_d_root="$case_d_repo/.specanchor/tasks"
mkdir -p "$case_d_root/agent_review_current" \
         "$case_d_root/agent_review_stale" \
         "$case_d_root/unrelated_task"

cat > "$case_d_root/agent_review_current/session.meta" <<'META'
MAIN_TERMINAL=term_main
WORKSPACE_ID=ws_main
META

cat > "$case_d_root/agent_review_stale/session.meta" <<'META'
MAIN_TERMINAL=term_main
WORKSPACE_ID=ws_main
META
printf 'stale_pane\n'       > "$case_d_root/agent_review_stale/.codex-pane-id"
printf 'stale_terminal\n'   > "$case_d_root/agent_review_stale/.codex-terminal-id"

# Unrelated task dir (non agent_review_ prefix) should NOT be scanned
cat > "$case_d_root/unrelated_task/session.meta" <<'META'
MAIN_TERMINAL=term_main
WORKSPACE_ID=ws_main
META
printf 'unrelated_pane\n'     > "$case_d_root/unrelated_task/.codex-pane-id"
printf 'unrelated_terminal\n' > "$case_d_root/unrelated_task/.codex-terminal-id"

case_d_shim="$WORKDIR/case_d_shim"
mkdir -p "$case_d_shim"
case_d_sentinel="$WORKDIR/case_d_closed.log"
: > "$case_d_sentinel"
cat > "$case_d_shim/herdr" <<SHIM
#!/usr/bin/env bash
case "\$1 \$2" in
  "pane get")   printf '{"result":{"pane":{"terminal_id":"stale_terminal","agent_status":"done"}}}\n' ;;
  "pane close") printf '%s\n' "\$3" >> "$case_d_sentinel" ;;
  *) : ;;
esac
SHIM
chmod +x "$case_d_shim/herdr"

PATH="$case_d_shim:$PATH" \
  "$SCRIPT_DIR/cleanup_stale_panes.sh" "$case_d_root/agent_review_current" term_main ws_main

grep -qx 'stale_pane' "$case_d_sentinel" || die "D: expected stale_pane closed; sentinel=$(cat "$case_d_sentinel")"
if grep -qx 'unrelated_pane' "$case_d_sentinel"; then
  die "D: unrelated_task dir (non agent_review_ prefix) should NOT be scanned"
fi
pass "D: only agent_review_* dirs scanned; unrelated dirs ignored"

# ─────────────────────────────────────────────────────────────────────────────
# init_session.sh requires HERDR_ENV + a live herdr server, so it can't run in
# this sandbox. Still verify it parses and rejects missing HERDR_PANE_ID.
step "init_session.sh — subagent mode works without HERDR_PANE_ID"
_SUBAGENT_OUT="$(REVIEW_MODE=subagent env -u HERDR_PANE_ID -u HERDR_ENV "$SCRIPT_DIR/init_session.sh" 2>/dev/null)" || die "init_session should succeed in subagent mode without HERDR_PANE_ID"
echo "$_SUBAGENT_OUT" | grep -q 'agent_review_.*-pane-subagent-' || die "subagent session ID should contain -pane-subagent-"
_SUBAGENT_ENV="$_SUBAGENT_OUT/session.env"
grep -q "MAIN_PANE='subagent-virtual'" "$_SUBAGENT_ENV" || die "subagent session.env should have MAIN_PANE=subagent-virtual"
grep -q "REVIEW_MODE='subagent'" "$_SUBAGENT_ENV" || die "subagent session.env should have REVIEW_MODE=subagent"
rm -rf "$_SUBAGENT_OUT"
pass "subagent mode without HERDR_PANE_ID -> OK"

# Smoke-test the POSIX single-quote escape function in init_session.sh against a
# value with apostrophes + spaces, by sourcing init_session.sh's escape logic
# via an inline copy. This guards F-1's "cwd with 'apos' space" promise without
# requiring a live herdr session.
APOS_TEST='value with '\''apos'\'' and space'
QUOTED="$(python3 -c '
import sys
v = sys.argv[1]
print("VAR=" + "\x27" + v.replace("\x27", "\x27\\\x27\x27") + "\x27")
' "$APOS_TEST")"
# Evaluate the quoted assignment in a subshell to confirm round-trip.
ROUND_TRIP="$(bash -c "$QUOTED; printf %s \"\$VAR\"")"
[ "$ROUND_TRIP" = "$APOS_TEST" ] || die "POSIX quote round-trip failed: got '$ROUND_TRIP'"
pass "POSIX single-quote escape preserves apos + space round-trip"

# ─────────────────────────────────────────────────────────────────────────────
step "preflight.sh — REVIEW_MODE=subagent skips codex CLI check"
# Hermetic isolated bin: real tool symlinks (no codex), plus a stub herdr.
pf_iso="$WORKDIR/pf_iso_bin"
mkdir -p "$pf_iso"
for c in bash env python3 grep head tr date sed cat; do
  p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$pf_iso/$c"
done
# python3 may be a pyenv/venv shim that can't resolve under an isolated PATH;
# symlink the real interpreter so preflight's pyyaml hard-check runs hermetically.
ln -sf "$(python3 -c 'import sys; print(sys.executable)')" "$pf_iso/python3"
cat > "$pf_iso/herdr" <<'H'
#!/usr/bin/env bash
exit 0
H
chmod +x "$pf_iso/herdr"
# NOTE: deliberately NO codex in $pf_iso

# Fake SA_SKILL_DIR with the two files preflight hard-checks.
pf_sa="$WORKDIR/pf_sa"
mkdir -p "$pf_sa/scripts"
: > "$pf_sa/SKILL.md"
: > "$pf_sa/scripts/specanchor-boot.sh"

# Fake repo with anchor.yaml (default task_specs) + .specanchor/
pf_repo="$WORKDIR/pf_repo"
mkdir -p "$pf_repo/.specanchor"
printf 'paths:\n  task_specs: .specanchor/tasks\n' > "$pf_repo/anchor.yaml"

# subagent mode: must pass even though codex is absent from PATH
if ( cd "$pf_repo" && HERDR_ENV=1 HERDR_PANE_ID=p REVIEW_MODE=subagent \
     SA_SKILL_DIR="$pf_sa" PATH="$pf_iso" "$SCRIPT_DIR/preflight.sh" >/dev/null 2>&1 ); then
  pass "preflight subagent mode OK without codex on PATH"
else
  die "preflight subagent mode should pass without codex, but it failed"
fi

# codex mode: same env must FAIL because codex is absent
if ( cd "$pf_repo" && HERDR_ENV=1 HERDR_PANE_ID=p REVIEW_MODE=codex \
     SA_SKILL_DIR="$pf_sa" PATH="$pf_iso" "$SCRIPT_DIR/preflight.sh" >/dev/null 2>&1 ); then
  die "preflight codex mode should FAIL without codex on PATH, but it passed"
else
  pass "preflight codex mode correctly fails without codex"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "subagent-review-v1.md — renders with SPEC_CONTEXT_FILE + PLAN_PATH + OUTPUT_PATH"
SUB_V1_TPL="$SKILL_DIR/prompts/subagent-review-v1.md"
[ -f "$SUB_V1_TPL" ] || die "subagent-review-v1.md not found at $SUB_V1_TPL"
SUB_V1_PLAN="$WORKDIR/sub_v1_plan.md"
SUB_V1_CTX="$WORKDIR/sub_v1_ctx.md"
printf 'dummy plan\n' > "$SUB_V1_PLAN"
printf 'ctx alpha\nctx beta\n' > "$SUB_V1_CTX"
SUB_V1_OUT="$("$SCRIPT_DIR/render_template.py" "$SUB_V1_TPL" \
  "PLAN_PATH=$SUB_V1_PLAN" \
  "OUTPUT_PATH=$WORKDIR/sub_v1_output.yaml" \
  "SPEC_CONTEXT_FILE=$SUB_V1_CTX")" || die "subagent-review-v1 render failed"
case "$SUB_V1_OUT" in *'{{SPEC_CONTEXT}}'*) die "unresolved {{SPEC_CONTEXT}} in subagent-review-v1" ;; esac
case "$SUB_V1_OUT" in *'{{PLAN_PATH}}'*) die "unresolved {{PLAN_PATH}} in subagent-review-v1" ;; esac
case "$SUB_V1_OUT" in *'{{OUTPUT_PATH}}'*) die "unresolved {{OUTPUT_PATH}} in subagent-review-v1" ;; esac
case "$SUB_V1_OUT" in *'ctx alpha'*'ctx beta'*) ;; *) die "spec context not injected into subagent-review-v1" ;; esac
case "$SUB_V1_OUT" in *'adversarial reviewer'*) ;; *) die "subagent-review-v1 missing adversarial-role framing" ;; esac
pass "subagent-review-v1 renders, no unresolved tokens, adversarial framing present"

# ─────────────────────────────────────────────────────────────────────────────
step "subagent-review-vn.md — renders self-contained (schema + spec context + diff + dispo)"
SUB_VN_TPL="$SKILL_DIR/prompts/subagent-review-vn.md"
[ -f "$SUB_VN_TPL" ] || die "subagent-review-vn.md not found at $SUB_VN_TPL"
SUB_VN_PLAN="$WORKDIR/sub_vn_plan.md"
SUB_VN_CTX="$WORKDIR/sub_vn_ctx.md"
SUB_VN_DISPO="$WORKDIR/sub_vn_dispo.yaml"
SUB_VN_DIFF="$WORKDIR/sub_vn.diff"
printf 'dummy plan v2\n' > "$SUB_VN_PLAN"
printf 'ctx gamma\n'     > "$SUB_VN_CTX"
printf 'dummy dispo\n'   > "$SUB_VN_DISPO"
printf 'dummy diff\n'    > "$SUB_VN_DIFF"
SUB_VN_OUT="$("$SCRIPT_DIR/render_template.py" "$SUB_VN_TPL" \
  "PLAN_PATH=$SUB_VN_PLAN" \
  "PREV_DISPOSITION=$SUB_VN_DISPO" \
  "DIFF_PATH=$SUB_VN_DIFF" \
  "OUTPUT_PATH=$WORKDIR/sub_vn_output.yaml" \
  "SPEC_CONTEXT_FILE=$SUB_VN_CTX")" || die "subagent-review-vn render failed"
for tok in '{{SPEC_CONTEXT}}' '{{PLAN_PATH}}' '{{PREV_DISPOSITION}}' '{{DIFF_PATH}}' '{{OUTPUT_PATH}}'; do
  case "$SUB_VN_OUT" in *"$tok"*) die "unresolved $tok in subagent-review-vn" ;; esac
done
case "$SUB_VN_OUT" in *'ctx gamma'*) ;; *) die "spec context not injected into subagent-review-vn" ;; esac
# Self-contained: must carry its own schema (subagent is stateless across rounds)
case "$SUB_VN_OUT" in *'overall_verdict:'*'review_comments:'*) ;; *) die "subagent-review-vn must inline the full schema (stateless reviewer)" ;; esac
case "$SUB_VN_OUT" in *'adversarial reviewer'*) ;; *) die "subagent-review-vn missing adversarial-role framing" ;; esac
case "$SUB_VN_OUT" in *'Severity guidance'*) ;; *) die "subagent-review-vn must inline severity rubric (stateless reviewer can't recover it)" ;; esac
pass "subagent-review-vn renders self-contained with schema + spec context + adversarial framing"

# ─────────────────────────────────────────────────────────────────────────────
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
