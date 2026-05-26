---
name: ralph-code-review
description: Use during review phase or after each optimization task. Review NumPy C optimization code for correctness, performance, safety, and style. Triggers when reviewing optimization patches, evaluating task completion, or before marking COMPLETE.
---

# Ralph Code Review — Optimization Patch Review

Adapted from Superpowers' code review skill. Focused on reviewing NumPy C extension optimization patches across 5 dimensions.

## When to Use

- **Review phase**: comprehensive review of all optimization tasks
- **After each task**: quick self-review before marking task complete
- **Before COMPLETE**: final review of all accumulated changes

## Five Review Dimensions

### 1. Correctness
- Does the optimization produce identical results to the original code?
- Are edge cases handled correctly? (NaN, Inf, zero, negative zero, denormalized numbers)
- Are loop bounds correct after unrolling/vectorizing?
- Does it handle all dtype variations (float32, float64, complex)?
- Strided vs contiguous access — both paths correct?

Check with:
```bash
python -m pytest numpy/core/tests/ -x -q -k "<relevant_test_pattern>"
```

### 2. Performance Impact
- What is the measured perf_change_pct vs baseline?
- Is the improvement consistent across input sizes (small, medium, large)?
- Does the optimization introduce any new overhead for edge cases?
- Is the benchmark result reproducible? (run twice, compare)
- If perf_change < 0%: is the approach fundamentally flawed or fixable?

### 3. Platform Safety
- Does the code use `NPY_SIMD` abstractions or platform-specific intrinsics?
- If NEON/SVE intrinsics used: is there an SSE/AVX fallback?
- Are alignment requirements satisfied? (`NPY_ALIGNED` macros)
- Does it compile on all target architectures? (check for `#ifdef`)
- Endianness assumptions? (should be handled by NumPy macros)

### 4. Code Quality
- Is the change minimal? (only what's needed for the optimization)
- Does it follow NumPy code style? (indentation, naming, comments)
- Are there any "magic numbers" that should be named constants?
- Is there dead code left from the original implementation?
- Does it introduce unnecessary abstractions?

### 5. Testing & Verification
- Were all 3 verification steps completed? (compile, test, benchmark)
- Is there a decision record in `decisions.jsonl`?
- Is `progress.txt` updated with the result?
- Is the git commit message in `PERF: <description>` format?
- Are `runtime/` files excluded from git?

## Issue Severity

| Level | Definition | Action |
|-------|-----------|--------|
| **Critical** | Wrong results, segfault, platform breakage | Must fix before task marked complete |
| **Important** | Performance regression, missing edge case, alignment risk | Should fix before next task |
| **Minor** | Style issue, naming, unused variable, missing comment | Note for later, don't block progress |

## Self-Review Checklist (Before Marking Task Complete)

- [ ] Benchmark shows improvement ≥ 2%
- [ ] All tests pass (`pytest numpy/core/tests/ -x -q`)
- [ ] No platform-specific intrinsics without fallback
- [ ] Code follows NumPy conventions
- [ ] `decisions.jsonl` has a valid JSON record for this task
- [ ] `progress.txt` has been appended (Chinese format)
- [ ] Git commit created with `PERF:` prefix
