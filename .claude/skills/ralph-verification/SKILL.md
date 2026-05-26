---
name: ralph-verification
description: Use before declaring an optimization task or the entire loop COMPLETE. Mandatory verification checklist to prevent premature completion. Triggers in review phase and before marking any task as passed.
---

# Ralph Verification — Completion Gate

Adapted from Superpowers' verification-before-completion skill. Ensures optimization work is truly done before declaring completion.

## Iron Law

**No COMPLETE declaration without this checklist fully verified.** If any item fails, the task or loop is NOT complete.

## Task-Level Verification (Before Marking `passed`)

Run this checklist after the 3-step verification pipeline (compile → test → benchmark):

- [ ] **Benchmark ran with exact `-b` parameter** from `prd.json` > `baselinePerf.benchmark`
- [ ] **No grep/awk/tail/head** used to filter ASV output — only exact `-b` matching
- [ ] **perf_change_pct ≥ 2%** (or ≥ 0% for refactoring tasks)
- [ ] **All correctness tests pass** — `pytest numpy/core/tests/ -x -q` exits 0
- [ ] **No new compiler warnings** — check build output for new warnings
- [ ] **decisions.jsonl updated** — single valid JSON line appended
- [ ] **progress.txt updated** — Chinese format, includes perf change and key findings
- [ ] **prd.json updated** — task status, actualImprovement, attemptCount
- [ ] **Git committed** — `PERF: <description>` format, no `runtime/` files staged

If all checked: task is `passed`. If any unchecked due to <2% improvement: task is `attempted`.

## Loop-Level Verification (Before COMPLETE in Review Phase)

Run during review phase. All task-level checks should already pass for each task.

### 1. End-to-End Benchmark Comparison

Run the full benchmark set from `baselinePerf.benchmarks` array (all entries) against current code:

```bash
# Build -b args from all benchmarks in the array
cd benchmarks && asv run --python=same \
  -b "<benchmark_1>" \
  -b "<benchmark_2>" \
  ...
```

Compare against `baselinePerf.benchmarks[].before` values.

### 2. Goal Achievement Check

**Primary check: user_intent.end_goal (from analysis.json)**

- [ ] Read `analysis.json` → `user_intent.end_goal`
- [ ] For each target in `end_goal.targets`, check if it's met:
  - `relative_improvement`: calculated improvement ≥ target_pct
  - `absolute_time`: current time ≤ target_value
  - `eliminate_regression`: all regression flags resolved (ratio ≤ 1.05)
  - `max_improvement`: within 1.1× of hardware_ceiling
- [ ] Record each target's status (met/unmet) in progress.txt

**Secondary checks:**

- [ ] Calculate GeometricMean of ratios (see phase-review.md for formula)
- [ ] Compare current performance with `targetPerf.time`
- [ ] Compare current performance with `hardware_ceiling.ceiling_time_us`

### 3. Decision Path Validation

**end_goal takes priority over hardware_ceiling.** Choose exactly one:

| Condition | Path |
|-----------|------|
| All must_have `end_goal.targets` are met | **Path A**: Goal achieved → COMPLETE |
| Some must_have targets unmet BUT within 1.1× `ceiling_time_us` | **Path B**: Hardware limit → COMPLETE (record unmet targets + reason) |
| Some must_have targets unmet AND > 1.5× `ceiling_time_us` AND new profitable directions exist | **Path C**: Continue with new tasks (target unmet goals) |
| No must_have targets defined (max_improvement) AND within 1.1× `ceiling_time_us` | **Path B**: Hardware limit → COMPLETE |

If `end_goal` is empty or missing from analysis.json: fall back to comparing against `targetPerf` and `hardware_ceiling` as before.

### 4. Before Writing COMPLETE

- [ ] `user_intent.end_goal` has been read and all targets have been checked
- [ ] Each end_goal target's status (met/unmet) is documented in progress.txt with explanation
- [ ] All pending tasks have been attempted (none left as `pending` without a plan)
- [ ] All `dependsOn` chains have been evaluated for combined effect
- [ ] `decisions.jsonl` contains a review record for this review iteration
- [ ] `progress.txt` contains the review summary with GeometricMean calculation
- [ ] No `state.json` modification occurred (script-managed only)

### 5. COMPLETE Tag

Only after all checks pass, append to `progress.txt`:
```
<promise>COMPLETE</promise>
```

## Red Flags — "Not Done" Signals

- Benchmark not re-run with current code during review
- "Looks good" without looking at the numbers
- Skipping the GeometricMean calculation for multi-benchmark cases
- Ignoring a <2% improvement task without documenting the reason
- Writing COMPLETE while pending tasks still have unexplored `dependsOn` chains
- Writing COMPLETE without checking `user_intent.end_goal` from analysis.json
- Writing COMPLETE while must_have end_goal targets are unmet and hardware limit not yet reached
- Declaring "hardware limit" without comparing against `hardware_ceiling.ceiling_time_us`
