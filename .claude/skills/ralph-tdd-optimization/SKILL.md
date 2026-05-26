---
name: ralph-tdd-optimization
description: Use when implementing NumPy C extension optimizations. Write the ASV benchmark verification FIRST, then implement the minimal optimization to pass it. Triggers during execute phase before modifying any C source code.
---

# Ralph TDD Optimization — Benchmark-Driven Performance Engineering

Adapted from Superpowers' TDD skill. Instead of correctness tests, this skill uses ASV benchmarks as the "test" that the optimization must pass.

## Iron Law

**NO C SOURCE CHANGE WITHOUT A BENCHMARK BASELINE FIRST.** If you modify `numpy/core/src/` without first confirming the benchmark runs and recording the baseline, revert your changes and start with this skill.

## The Performance RED-GREEN-REFACTOR Cycle

### 1. RED — Confirm Baseline Regression

Before modifying code:
1. Run the exact benchmark from `prd.json` > `baselinePerf.benchmark`:
   ```bash
   cd benchmarks && asv run --python=same -b "<exact_benchmark_name>"
   ```
2. Record the current time as `perf_before` (this is your baseline to beat)
3. Verify the benchmark runs successfully — if it doesn't, the "test" is broken, not the code

### 2. GREEN — Implement Minimum Optimization

Write the **simplest** optimization that achieves the target improvement:
- One optimization direction at a time
- No bundling of multiple unrelated changes
- No "while I'm here" refactoring
- Target: achieve `expectedImprovement` from the task spec

### 3. REFACTOR — Clean Up (Only if GREEN)

After the benchmark shows improvement:
- Remove dead code the optimization made obsolete
- Ensure the change follows NumPy code style
- Commit: `git add <files> && git commit -m "PERF: <description>"`

## Verification Pipeline (Run in Order)

```bash
# Step 1: Compile
pip install --no-build-isolation -e .

# Step 2: Correctness Tests
python -m pytest numpy/core/tests/ -x -q

# Step 3: Benchmark (exact match from prd.json)
cd benchmarks && asv run --python=same -b "<exact_benchmark_name>"
```

**If any step fails, the task is not done.** Use `ralph-systematic-debugging` to investigate.

## Judgment Rules

After benchmark:

| Result | Action |
|--------|--------|
| perf_change ≥ expectedImprovement × 0.8 AND tests pass | Mark task `passed` |
| 2% ≤ perf_change < expectedImprovement × 0.8 | Mark `attempted`, document reason |
| -2% < perf_change < 2% (no significant change) | Mark `attempted`, document reason |
| perf_change ≤ -2% (regression) | Revert code, mark `rolled_back` |
| Tests fail or segfault | Fix or revert, mark `rolled_back` |

## Red Flags

- Writing C code before running the baseline benchmark
- Multiple unrelated optimization changes in one task
- Skipping the correctness test ("it's a simple change")
- Accepting <2% improvement as "passed"
