---
name: ralph-systematic-debugging
description: Use when optimization code fails compilation, tests, or shows unexpected benchmark regression. Systematic root-cause analysis before any fix attempt. Triggers on build failure, test failure, segmentation fault, or >10% performance regression.
---

# Ralph Systematic Debugging — Root Cause Analysis for Optimization

Adapted from Superpowers' systematic debugging skill. Applied to NumPy C extension optimization failures.

## Iron Law

**NO FIX WITHOUT ROOT CAUSE INVESTIGATION FIRST.** If you propose a fix before completing Phase 1, delete it and start over.

## When to Use

This is **mandatory** for:
- `pip install --no-build-isolation -e .` compilation failure
- `python -m pytest numpy/core/tests/ -x -q` test failure
- ASV benchmark shows >10% regression
- Segmentation fault or undefined behavior during testing

Don't skip even when:
- The fix seems "obvious"
- You're under iteration time pressure
- It's "just a small tweak"

## Four Phases

### Phase 1: Root Cause Investigation (No fixes yet!)

1. **Read the error completely** — full compiler output, full test failure message, full stack trace
2. **Isolate the change** — `git diff` to see exactly what changed; did the optimization touch more than intended?
3. **For compilation failures**:
   - Is it a syntax error, type mismatch, or missing include?
   - Does it fail on all platforms or just this one (NEON vs SSE)?
   - Check: does the error reference a line you changed or something your change affects?
4. **For test failures**:
   - What specific assertion failed? Expected vs actual values?
   - Is it a correctness issue (wrong result) or a crash (segfault)?
   - Run the single failing test with verbose output to get the exact input case
5. **For benchmark regressions**:
   - Did you accidentally disable an existing optimization?
   - Does the new code path handle the benchmark's specific input sizes poorly?
   - Check: is the regression across all input sizes or only at certain sizes?

### Phase 2: Pattern Analysis

Before fixing, find working examples in the NumPy codebase:
- Search for similar optimizations in `numpy/core/src/` that work correctly
- Compare your implementation against the working example line by line
- Identify every difference — algorithm, data types, loop bounds, alignment, intrinsics

### Phase 3: Hypothesis and Testing

1. State a single hypothesis: "The failure is caused by [X] because [Y]"
2. Test with the **smallest possible change** — change one line, recompile, retest
3. If confirmed: proceed to Phase 4
4. If disproven: form new hypothesis, do NOT pile on changes
5. After 3 failed fix attempts: **STOP**. The task's approach may be fundamentally wrong. Mark the task as `attempted`, document findings in decisions.jsonl, and move to the next task.

### Phase 4: Fix and Verify

1. Apply the single fix (one change at a time)
2. Run the full verification pipeline:
   ```bash
   pip install --no-build-isolation -e .
   python -m pytest numpy/core/tests/ -x -q
   cd benchmarks && asv run --python=same -b "<exact_benchmark_name>"
   ```
3. If the fix works: record the root cause and fix in decisions.jsonl
4. If the fix fails: increment attempt counter, return to Phase 1

## Red Flags

Cognitive traps that signal "return to Phase 1":
- "Quick fix for now, investigate later"
- "Just try changing X and see if it works"
- Multiple simultaneous changes
- Skipping benchmark verification after fix
- "One more fix attempt" after 2+ failures
