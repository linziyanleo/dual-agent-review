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
step "validate_findings.py — 5 broken fixtures + happy path"
fixture_dir="$WORKDIR/findings"
mkdir -p "$fixture_dir"

# (a) empty file
: > "$fixture_dir/empty.yaml"
"$SCRIPT_DIR/validate_findings.py" "$fixture_dir/empty.yaml" >/dev/null && die "empty file should fail" || pass "empty file -> fail"

# (b) missing required key (no overall_verdict)
cat > "$fixture_dir/no_verdict.yaml" <<'YAML'
summary: x
findings: []
YAML
"$SCRIPT_DIR/validate_findings.py" "$fixture_dir/no_verdict.yaml" >/dev/null && die "missing verdict should fail" || pass "missing verdict -> fail"

# (c) invalid enum
cat > "$fixture_dir/bad_severity.yaml" <<'YAML'
overall_verdict: approve
summary: x
findings:
  - finding_id: F-1
    severity: catastrophic
    category: correctness
    location: x
    description: x
    suggested_change: x
    rationale: x
YAML
"$SCRIPT_DIR/validate_findings.py" "$fixture_dir/bad_severity.yaml" >/dev/null && die "bad severity should fail" || pass "invalid enum -> fail"

# (d) findings not a list
cat > "$fixture_dir/findings_not_list.yaml" <<'YAML'
overall_verdict: approve
summary: x
findings: oops
YAML
"$SCRIPT_DIR/validate_findings.py" "$fixture_dir/findings_not_list.yaml" >/dev/null && die "non-list findings should fail" || pass "findings non-list -> fail"

# (e) duplicate finding_id
cat > "$fixture_dir/dup_id.yaml" <<'YAML'
overall_verdict: approve
summary: x
findings:
  - {finding_id: F-1, severity: high, category: correctness, location: x, description: x, suggested_change: x, rationale: x}
  - {finding_id: F-1, severity: low,  category: correctness, location: x, description: x, suggested_change: x, rationale: x}
YAML
OUT="$("$SCRIPT_DIR/validate_findings.py" "$fixture_dir/dup_id.yaml" 2>&1)" && die "dup id should fail" || true
case "$OUT" in *"duplicate finding_id"*"F-1"*) pass "dup finding_id -> fail with descriptive message" ;;
                                          *) die "dup_id error message lacks 'duplicate finding_id F-1': $OUT" ;;
esac

# happy path
cat > "$fixture_dir/happy.yaml" <<'YAML'
overall_verdict: request_changes
summary: a real summary
findings:
  - {finding_id: F-1, severity: high, category: security, location: foo:1, description: d, suggested_change: c, rationale: r}
  - {finding_id: F-2, severity: low,  category: testing,  location: foo:2, description: d, suggested_change: c, rationale: r}
YAML
"$SCRIPT_DIR/validate_findings.py" "$fixture_dir/happy.yaml" || die "happy path should pass"
pass "happy path -> 0"

# (f) cross-field: approve + any non-empty findings (high/medium/low/nit) must fail.
# Per prompts/codex-review-v1.md: approve means findings: [] — don't invent nits to fill space.
cat > "$fixture_dir/approve_with_high.yaml" <<'YAML'
overall_verdict: approve
summary: bogus
findings:
  - {finding_id: F-1, severity: high, category: correctness, location: x, description: d, suggested_change: c, rationale: r}
YAML
OUT="$("$SCRIPT_DIR/validate_findings.py" "$fixture_dir/approve_with_high.yaml" 2>&1)" && die "approve+high should fail" || true
case "$OUT" in *"requires findings: []"*) pass "approve+high -> fail with 'requires findings: []' message" ;;
                                        *) die "approve+high message should say 'requires findings: []': $OUT" ;;
esac

# (g) approve + low-only must also fail (the prompt forbids approve with ANY findings).
cat > "$fixture_dir/approve_with_low.yaml" <<'YAML'
overall_verdict: approve
summary: looks fine but here's a nit
findings:
  - {finding_id: F-1, severity: low, category: maintainability, location: x, description: d, suggested_change: c, rationale: r}
YAML
OUT="$("$SCRIPT_DIR/validate_findings.py" "$fixture_dir/approve_with_low.yaml" 2>&1)" && die "approve+low should fail" || true
case "$OUT" in *"requires findings: []"*) pass "approve+low -> fail (no nit smuggling past approve)" ;;
                                        *) die "approve+low message should say 'requires findings: []': $OUT" ;;
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
total_findings: 0
dispositions: []
YAML
"$SCRIPT_DIR/validate_dispositions.py" "$fixture_dir/empty.yaml" "$dd/v1.dispositions.yaml" >/dev/null && die "upstream invalid should fail" || pass "upstream findings invalid -> fail"

# (1) missing disposition entry for F-2
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_findings: 1
dispositions:
  - {finding_id: F-1, disposition: rejected, reason: nope}
YAML
"$SCRIPT_DIR/validate_dispositions.py" "$HAPPY_FINDINGS" "$dd/v1.dispositions.yaml" >/dev/null && die "missing disposition should fail" || pass "missing disposition -> fail"

# (2) invalid disposition enum
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_findings: 2
dispositions:
  - {finding_id: F-1, disposition: ignored, reason: nope}
  - {finding_id: F-2, disposition: rejected, reason: nope}
YAML
"$SCRIPT_DIR/validate_dispositions.py" "$HAPPY_FINDINGS" "$dd/v1.dispositions.yaml" >/dev/null && die "invalid enum should fail" || pass "invalid disposition enum -> fail"

# (3) rejected without reason
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_findings: 2
dispositions:
  - {finding_id: F-1, disposition: rejected, reason: ""}
  - {finding_id: F-2, disposition: rejected, reason: nope}
YAML
"$SCRIPT_DIR/validate_dispositions.py" "$HAPPY_FINDINGS" "$dd/v1.dispositions.yaml" >/dev/null && die "rejected w/o reason should fail" || pass "rejected w/o reason -> fail"

# (4) extra finding_id in dispositions (set inequality)
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_findings: 3
dispositions:
  - {finding_id: F-1, disposition: rejected, reason: nope}
  - {finding_id: F-2, disposition: rejected, reason: nope}
  - {finding_id: F-9, disposition: rejected, reason: nope}
YAML
"$SCRIPT_DIR/validate_dispositions.py" "$HAPPY_FINDINGS" "$dd/v1.dispositions.yaml" >/dev/null && die "extra finding_id should fail" || pass "extra finding_id -> fail"

# (5) duplicate finding_id in dispositions
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_findings: 2
dispositions:
  - {finding_id: F-1, disposition: rejected, reason: nope}
  - {finding_id: F-1, disposition: rejected, reason: nope}
YAML
"$SCRIPT_DIR/validate_dispositions.py" "$HAPPY_FINDINGS" "$dd/v1.dispositions.yaml" >/dev/null && die "dup finding_id should fail" || pass "dup finding_id -> fail"

# (6) total_findings mismatch
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_findings: 99
dispositions:
  - {finding_id: F-1, disposition: rejected, reason: nope}
  - {finding_id: F-2, disposition: rejected, reason: nope}
YAML
"$SCRIPT_DIR/validate_dispositions.py" "$HAPPY_FINDINGS" "$dd/v1.dispositions.yaml" >/dev/null && die "total_findings mismatch should fail" || pass "total_findings mismatch -> fail"

# (7) plan_version_reviewed doesn't match filename
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v9
total_findings: 2
dispositions:
  - {finding_id: F-1, disposition: rejected, reason: nope}
  - {finding_id: F-2, disposition: rejected, reason: nope}
YAML
"$SCRIPT_DIR/validate_dispositions.py" "$HAPPY_FINDINGS" "$dd/v1.dispositions.yaml" >/dev/null && die "version mismatch should fail" || pass "plan_version_reviewed mismatch -> fail"

# (8) incorporated without plan_change_summary
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_findings: 2
dispositions:
  - {finding_id: F-1, disposition: incorporated}
  - {finding_id: F-2, disposition: rejected, reason: nope}
YAML
"$SCRIPT_DIR/validate_dispositions.py" "$HAPPY_FINDINGS" "$dd/v1.dispositions.yaml" >/dev/null && die "incorporated w/o summary should fail" || pass "incorporated w/o plan_change_summary -> fail"

# happy
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_findings: 2
dispositions:
  - {finding_id: F-1, disposition: incorporated, plan_change_summary: did the thing}
  - {finding_id: F-2, disposition: rejected,     reason: not relevant}
YAML
"$SCRIPT_DIR/validate_dispositions.py" "$HAPPY_FINDINGS" "$dd/v1.dispositions.yaml" || die "happy dispositions should pass"
pass "happy dispositions -> 0"

# (9a) high deferred is rejected outright (even with reason + follow_up).
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_findings: 2
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
findings:
  - {finding_id: F-1, severity: medium, category: correctness, location: x, description: d, suggested_change: c, rationale: r}
YAML
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_findings: 1
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
findings:
  - {finding_id: F-1, severity: low, category: maintainability, location: x, description: d, suggested_change: c, rationale: r}
YAML
cat > "$dd/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_findings: 1
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
cat > "$cv/v1.findings.yaml" <<'YAML'
overall_verdict: approve
summary: ok
findings: []
YAML
OUT="$("$SCRIPT_DIR/check_convergence.py" "$cv" 1)"
[ "$OUT" = "CONVERGED_APPROVE" ] || die "expected CONVERGED_APPROVE, got $OUT"
pass "v1 approve -> CONVERGED_APPROVE (exit 0)"

# CONTINUE on v1 with request_changes + medium finding.
cat > "$cv/v1.findings.yaml" <<'YAML'
overall_verdict: request_changes
summary: x
findings:
  - {finding_id: F-1, severity: medium, category: correctness, location: x, description: d, suggested_change: c, rationale: r}
YAML
OUT="$("$SCRIPT_DIR/check_convergence.py" "$cv" 1)"
[ "$OUT" = "CONTINUE" ] || die "expected CONTINUE, got $OUT"
pass "v1 request_changes w/ medium -> CONTINUE (exit 0)"

# CONVERGED_NO_BLOCKERS on v2 when v1 + v2 both have only low/nit (with dispositions written).
cat > "$cv/v1.findings.yaml" <<'YAML'
overall_verdict: request_changes
summary: x
findings:
  - {finding_id: F-1, severity: low, category: correctness, location: x, description: d, suggested_change: c, rationale: r}
YAML
cat > "$cv/v2.findings.yaml" <<'YAML'
overall_verdict: request_changes
summary: x
findings:
  - {finding_id: F-1, severity: nit, category: correctness, location: x, description: d, suggested_change: c, rationale: r}
YAML
cat > "$cv/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_findings: 1
dispositions:
  - {finding_id: F-1, disposition: deferred}
YAML
cat > "$cv/v2.dispositions.yaml" <<'YAML'
plan_version_reviewed: v2
total_findings: 1
dispositions:
  - {finding_id: F-1, disposition: deferred}
YAML
OUT="$("$SCRIPT_DIR/check_convergence.py" "$cv" 2)"
[ "$OUT" = "CONVERGED_NO_BLOCKERS" ] || die "expected CONVERGED_NO_BLOCKERS, got $OUT"
pass "v1+v2 no blockers + dispositions written -> CONVERGED_NO_BLOCKERS (exit 0)"
rm -f "$cv"/v?.dispositions.yaml

# MAX_ROUNDS_REACHED at round 5 with still-pending medium (with dispositions written every round).
for n in 1 2 3 4 5; do
  cat > "$cv/v${n}.findings.yaml" <<YAML
overall_verdict: request_changes
summary: x
findings:
  - {finding_id: F-1, severity: medium, category: correctness, location: x, description: d, suggested_change: c, rationale: r}
YAML
  cat > "$cv/v${n}.dispositions.yaml" <<YAML
plan_version_reviewed: v${n}
total_findings: 1
dispositions:
  - {finding_id: F-1, disposition: rejected, reason: "tracked in external ticket FOO-${n}"}
YAML
done
OUT="$("$SCRIPT_DIR/check_convergence.py" "$cv" 5)"
[ "$OUT" = "MAX_ROUNDS_REACHED" ] || die "expected MAX_ROUNDS_REACHED, got $OUT"
pass "round 5 unresolved + dispositions written -> MAX_ROUNDS_REACHED (exit 0)"
rm -f "$cv"/v?.dispositions.yaml

# block verdict with only low/nit findings must still block convergence
rm -f "$cv/v1.findings.yaml" "$cv/v2.findings.yaml"
cat > "$cv/v1.findings.yaml" <<'YAML'
overall_verdict: request_changes
summary: x
findings:
  - {finding_id: F-1, severity: low, category: correctness, location: x, description: d, suggested_change: c, rationale: r}
YAML
cat > "$cv/v2.findings.yaml" <<'YAML'
overall_verdict: block
summary: pipeline broken
findings:
  - {finding_id: F-1, severity: low, category: correctness, location: x, description: d, suggested_change: c, rationale: r}
YAML
OUT="$("$SCRIPT_DIR/check_convergence.py" "$cv" 2)"
[ "$OUT" = "CONTINUE" ] || die "expected CONTINUE (block beats low), got $OUT"
pass "block verdict + only-low -> CONTINUE (block is always a blocker)"

# Workflow gate (v3 F-1): findings non-empty but v(N).dispositions.yaml missing
# must return CONTINUE — the loop cannot finalize without recording dispositions
# for the current round, even for low-only request_changes.
rm -f "$cv"/v?.findings.yaml "$cv"/v?.dispositions.yaml
cat > "$cv/v1.findings.yaml" <<'YAML'
overall_verdict: request_changes
summary: x
findings:
  - {finding_id: F-1, severity: low, category: style, location: x, description: d, suggested_change: c, rationale: r}
YAML
cat > "$cv/v2.findings.yaml" <<'YAML'
overall_verdict: request_changes
summary: x
findings:
  - {finding_id: F-1, severity: low, category: style, location: x, description: d, suggested_change: c, rationale: r}
YAML
# v2.dispositions.yaml deliberately absent.
OUT="$("$SCRIPT_DIR/check_convergence.py" "$cv" 2)"
[ "$OUT" = "CONTINUE" ] || die "expected CONTINUE (v2.dispositions missing), got $OUT"
pass "request_changes + low-only + missing v(N).dispositions -> CONTINUE (workflow gate)"

# Same setup but with v2.dispositions present should now hit rule B (no blockers across v1+v2).
cat > "$cv/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_findings: 1
dispositions:
  - {finding_id: F-1, disposition: deferred}
YAML
cat > "$cv/v2.dispositions.yaml" <<'YAML'
plan_version_reviewed: v2
total_findings: 1
dispositions:
  - {finding_id: F-1, disposition: deferred}
YAML
OUT="$("$SCRIPT_DIR/check_convergence.py" "$cv" 2)"
[ "$OUT" = "CONVERGED_NO_BLOCKERS" ] || die "expected CONVERGED_NO_BLOCKERS with dispositions written, got $OUT"
pass "low-only + v(N).dispositions written -> CONVERGED_NO_BLOCKERS (gate releases)"
rm -f "$cv"/v?.findings.yaml "$cv"/v?.dispositions.yaml

# ─────────────────────────────────────────────────────────────────────────────
step "append_rejected_section.py — cross-3-round idempotent"
ar="$WORKDIR/append"
mkdir -p "$ar"
# Build minimal findings + dispositions for v1/v2/v3 with mixed rejected.
for n in 1 2 3; do
  cat > "$ar/v${n}.findings.yaml" <<YAML
overall_verdict: request_changes
summary: x
findings:
  - {finding_id: F-${n}A, severity: medium, category: correctness, location: x, description: "round ${n} A desc", suggested_change: c, rationale: r}
  - {finding_id: F-${n}B, severity: low,    category: scope,       location: x, description: "round ${n} B desc", suggested_change: c, rationale: r}
YAML
done
cat > "$ar/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_findings: 2
dispositions:
  - {finding_id: F-1A, disposition: incorporated, plan_change_summary: ok}
  - {finding_id: F-1B, disposition: rejected,     reason: not relevant in v1}
YAML
cat > "$ar/v2.dispositions.yaml" <<'YAML'
plan_version_reviewed: v2
total_findings: 2
dispositions:
  - {finding_id: F-2A, disposition: rejected, reason: out of scope}
  - {finding_id: F-2B, disposition: deferred}
YAML
cat > "$ar/v3.dispositions.yaml" <<'YAML'
plan_version_reviewed: v3
total_findings: 2
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
cat > "$arh/v1.findings.yaml" <<'YAML'
overall_verdict: request_changes
summary: x
findings:
  - {finding_id: F-1, severity: high, category: correctness, location: x, description: "load-bearing bug", suggested_change: c, rationale: r}
YAML
cat > "$arh/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_findings: 1
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
cat > "$arb/v1.findings.yaml" <<'YAML'
overall_verdict: request_changes
summary: x
findings:
  - {finding_id: F-1, severity: low, category: style, location: x, description: "minor", suggested_change: c, rationale: r}
YAML
cat > "$arb/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_findings: 1
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
cat > "$arf/v1.findings.yaml" <<'YAML'
overall_verdict: request_changes
summary: x
findings:
  - {finding_id: F-1, severity: low, category: style, location: x, description: "minor", suggested_change: c, rationale: r}
YAML
cat > "$arf/v1.dispositions.yaml" <<'YAML'
plan_version_reviewed: v1
total_findings: 1
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
cleanup_root="$WORKDIR/cleanup/.plan/sessions"
mkdir -p "$cleanup_root/current"
mkdir -p "$cleanup_root/old"

# Current session metadata (does nothing; just to satisfy the loop's exclusion).
cat > "$cleanup_root/current/session.meta" <<'META'
MAIN_TERMINAL=term_main
WORKSPACE_ID=ws_main
META

# Old session: owned pane with terminal_id matching what fake herdr will return.
cat > "$cleanup_root/old/session.meta" <<'META'
MAIN_TERMINAL=term_main
WORKSPACE_ID=ws_main
META
printf 'old_pane\n'     > "$cleanup_root/old/.codex-pane-id"
printf 'old_terminal\n' > "$cleanup_root/old/.codex-terminal-id"

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
touch -t 202001010000 "$cleanup_root/old"   # very old; well past any TTL
SHIM_PANE_STATUS=working DAR_PANE_TTL_SECS=7200 PATH="$SHIM_DIR:$PATH" \
  "$SCRIPT_DIR/cleanup_stale_panes.sh" "$cleanup_root/current" term_main ws_main
grep -qx 'old_pane' "$SENTINEL" || die "expected fake herdr to receive 'pane close old_pane', got: $(cat "$SENTINEL")"
grep -q 'AUTO_CLOSED_STALE_TTL' "$cleanup_root/old/session.log" || die "TTL close should log AUTO_CLOSED_STALE_TTL"
pass "TTL expired + working pane -> force-close + sentinel recorded + AUTO_CLOSED_STALE_TTL logged"

# Sub-test 2: mtime fresh (< TTL) with status=working -> must NOT close.
mkdir -p "$cleanup_root/fresh"
cat > "$cleanup_root/fresh/session.meta" <<'META'
MAIN_TERMINAL=term_main
WORKSPACE_ID=ws_main
META
printf 'fresh_pane\n'     > "$cleanup_root/fresh/.codex-pane-id"
printf 'fresh_terminal\n' > "$cleanup_root/fresh/.codex-terminal-id"

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
  "$SCRIPT_DIR/cleanup_stale_panes.sh" "$cleanup_root/current" term_main ws_main
if grep -qx 'fresh_pane' "$SENTINEL"; then
  die "fresh-mtime working pane must NOT be force-closed; sentinel: $(cat "$SENTINEL")"
fi
pass "fresh mtime + working pane -> no close (TTL not exceeded)"

# ─────────────────────────────────────────────────────────────────────────────
step "init_session.sh — path selection by repo layout (case A, v3)"
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

# A1: no anchor.yaml -> .plan/sessions fallback (no-spec-anchor case)
mkdir -p "$WORKDIR/repo-no-anchor"
SR_A1="$(cd "$WORKDIR/repo-no-anchor" && \
  HERDR_PANE_ID=p_a PATH="$case_a_shim:$PATH" "$SCRIPT_DIR/init_session.sh")"
case "$SR_A1" in
  "$WORKDIR/repo-no-anchor/.plan/sessions/"*) ;;
  *) die "A1: expected .plan/sessions path under repo-no-anchor, got $SR_A1" ;;
esac
grep -q "^SESSIONS_ROOT='$WORKDIR/repo-no-anchor/\.plan/sessions'$" "$SR_A1/session.env" \
  || die "A1: session.env SESSIONS_ROOT wrong: $(grep SESSIONS_ROOT "$SR_A1/session.env")"
grep -q "^SESSIONS_ROOT=$WORKDIR/repo-no-anchor/\.plan/sessions$" "$SR_A1/session.meta" \
  || die "A1: session.meta SESSIONS_ROOT wrong: $(grep SESSIONS_ROOT "$SR_A1/session.meta")"
pass "A1: no anchor.yaml -> .plan/sessions, session.{env,meta} record SESSIONS_ROOT"

# A2: anchor.yaml + .specanchor/ -> .specanchor/dual-agent-review/sessions (default spec-anchor layout)
mkdir -p "$WORKDIR/repo-with-anchor/.specanchor"
: > "$WORKDIR/repo-with-anchor/anchor.yaml"
SR_A2="$(cd "$WORKDIR/repo-with-anchor" && \
  HERDR_PANE_ID=p_a PATH="$case_a_shim:$PATH" "$SCRIPT_DIR/init_session.sh")"
case "$SR_A2" in
  "$WORKDIR/repo-with-anchor/.specanchor/dual-agent-review/sessions/"*) ;;
  *) die "A2: expected .specanchor/dual-agent-review/sessions path, got $SR_A2" ;;
esac
grep -q "^SESSIONS_ROOT='$WORKDIR/repo-with-anchor/\.specanchor/dual-agent-review/sessions'$" "$SR_A2/session.env" \
  || die "A2: session.env SESSIONS_ROOT wrong: $(grep SESSIONS_ROOT "$SR_A2/session.env")"
pass "A2: anchor.yaml + .specanchor/ -> .specanchor/dual-agent-review/sessions"

# A3: anchor.yaml only (no .specanchor/) -> .plan/sessions fallback (custom-layout R5)
mkdir -p "$WORKDIR/repo-custom-layout"
: > "$WORKDIR/repo-custom-layout/anchor.yaml"
SR_A3="$(cd "$WORKDIR/repo-custom-layout" && \
  HERDR_PANE_ID=p_a PATH="$case_a_shim:$PATH" "$SCRIPT_DIR/init_session.sh")"
case "$SR_A3" in
  "$WORKDIR/repo-custom-layout/.plan/sessions/"*) ;;
  *) die "A3: expected .plan/sessions fallback under repo-custom-layout, got $SR_A3" ;;
esac
grep -q "^SESSIONS_ROOT='$WORKDIR/repo-custom-layout/\.plan/sessions'$" "$SR_A3/session.env" \
  || die "A3: session.env SESSIONS_ROOT wrong: $(grep SESSIONS_ROOT "$SR_A3/session.env")"
pass "A3: anchor.yaml without .specanchor/ -> .plan/sessions fallback (R5 covered)"

# ─────────────────────────────────────────────────────────────────────────────
step "cleanup_stale_panes.sh — dual-root scan covers .plan + .specanchor (case B, v3)"
case_b_repo="$WORKDIR/case_b_repo"
case_b_cur_root="$case_b_repo/.specanchor/dual-agent-review/sessions"
case_b_old_root="$case_b_repo/.plan/sessions"
mkdir -p "$case_b_cur_root/current-id" \
         "$case_b_cur_root/new-stale-id" \
         "$case_b_old_root/old-stale-id"

# Current (self) session's session.meta carries CWD so cleanup can derive LEGACY_ROOT.
cat > "$case_b_cur_root/current-id/session.meta" <<META
MAIN_TERMINAL=term_main
WORKSPACE_ID=ws_main
CWD=$case_b_repo
META

# Stale session in the new (spec-anchor) root.
cat > "$case_b_cur_root/new-stale-id/session.meta" <<'META'
MAIN_TERMINAL=term_main
WORKSPACE_ID=ws_main
META
printf 'new_pane\n'         > "$case_b_cur_root/new-stale-id/.codex-pane-id"
printf 'shared_terminal\n'  > "$case_b_cur_root/new-stale-id/.codex-terminal-id"

# Stale session in the legacy (.plan) root.
cat > "$case_b_old_root/old-stale-id/session.meta" <<'META'
MAIN_TERMINAL=term_main
WORKSPACE_ID=ws_main
META
printf 'old_pane\n'         > "$case_b_old_root/old-stale-id/.codex-pane-id"
printf 'shared_terminal\n'  > "$case_b_old_root/old-stale-id/.codex-terminal-id"

case_b_shim="$WORKDIR/case_b_shim"
mkdir -p "$case_b_shim"
case_b_sentinel="$WORKDIR/case_b_closed.log"
: > "$case_b_sentinel"
cat > "$case_b_shim/herdr" <<SHIM
#!/usr/bin/env bash
case "\$1 \$2" in
  "pane get")   printf '{"result":{"pane":{"terminal_id":"shared_terminal","agent_status":"done"}}}\n' ;;
  "pane close") printf '%s\n' "\$3" >> "$case_b_sentinel" ;;
  *) : ;;
esac
SHIM
chmod +x "$case_b_shim/herdr"

PATH="$case_b_shim:$PATH" \
  "$SCRIPT_DIR/cleanup_stale_panes.sh" "$case_b_cur_root/current-id" term_main ws_main

grep -qx 'new_pane' "$case_b_sentinel" || die "B: expected new_pane (spec-anchor root) closed; sentinel=$(cat "$case_b_sentinel")"
grep -qx 'old_pane' "$case_b_sentinel" || die "B: expected old_pane (.plan root) closed; sentinel=$(cat "$case_b_sentinel")"
pass "B: both .specanchor and .plan stale panes closed (dual-root scan covers migration window)"

# ─────────────────────────────────────────────────────────────────────────────
step "cleanup_stale_panes.sh — cwd independence + no env dep (case C, v3)"
# Reuse case_b_repo layout: rebuild stale panes that the previous case consumed.
mkdir -p "$case_b_cur_root/new-stale-id-2" "$case_b_old_root/old-stale-id-2"
cat > "$case_b_cur_root/new-stale-id-2/session.meta" <<'META'
MAIN_TERMINAL=term_main
WORKSPACE_ID=ws_main
META
printf 'new_pane_2\n'        > "$case_b_cur_root/new-stale-id-2/.codex-pane-id"
printf 'shared_terminal\n'   > "$case_b_cur_root/new-stale-id-2/.codex-terminal-id"
cat > "$case_b_old_root/old-stale-id-2/session.meta" <<'META'
MAIN_TERMINAL=term_main
WORKSPACE_ID=ws_main
META
printf 'old_pane_2\n'        > "$case_b_old_root/old-stale-id-2/.codex-pane-id"
printf 'shared_terminal\n'   > "$case_b_old_root/old-stale-id-2/.codex-terminal-id"

case_c_sentinel="$WORKDIR/case_c_closed.log"
: > "$case_c_sentinel"
cat > "$case_b_shim/herdr" <<SHIM
#!/usr/bin/env bash
case "\$1 \$2" in
  "pane get")   printf '{"result":{"pane":{"terminal_id":"shared_terminal","agent_status":"done"}}}\n' ;;
  "pane close") printf '%s\n' "\$3" >> "$case_c_sentinel" ;;
  *) : ;;
esac
SHIM

# Invoke from /tmp (NOT inside the temp repo) with an ABSOLUTE SESSION_ROOT and
# SESSIONS_ROOT explicitly UNSET. cleanup must still find both stale panes via
# SESSION_ROOT-derived current root + session.meta-derived legacy root.
( cd /tmp && unset SESSIONS_ROOT && \
  PATH="$case_b_shim:$PATH" \
  "$SCRIPT_DIR/cleanup_stale_panes.sh" "$case_b_cur_root/current-id" term_main ws_main )

grep -qx 'new_pane_2' "$case_c_sentinel" || die "C: expected new_pane_2 closed; sentinel=$(cat "$case_c_sentinel")"
grep -qx 'old_pane_2' "$case_c_sentinel" || die "C: expected old_pane_2 closed (legacy root from session.meta CWD); sentinel=$(cat "$case_c_sentinel")"
pass "C: cleanup correct from /tmp with absolute SESSION_ROOT and SESSIONS_ROOT unset"

# ─────────────────────────────────────────────────────────────────────────────
# init_session.sh requires HERDR_ENV + a live herdr server, so it can't run in
# this sandbox. Still verify it parses and rejects missing HERDR_PANE_ID.
step "init_session.sh — refuses without HERDR_PANE_ID"
( unset HERDR_PANE_ID; "$SCRIPT_DIR/init_session.sh" >/dev/null 2>&1 ) && die "init_session should fail without HERDR_PANE_ID" || pass "no HERDR_PANE_ID -> abort"

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
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
