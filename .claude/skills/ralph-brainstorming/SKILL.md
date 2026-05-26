---
name: ralph-brainstorming
description: Use during bootstrap phase before writing PRD. Generate multiple optimization strategies for NumPy C extensions, compare tradeoffs, and select the most promising direction. Triggers when analyzing performance hotspots, exploring SIMD/NEON vectorization opportunities, or designing optimization approaches.
---

# Ralph Brainstorming — Optimization Strategy Design

This skill applies Superpowers' brainstorming discipline to NumPy C extension performance optimization. It activates during Ralph Loop's bootstrap phase, before generating `prd.json`.

## Iron Law

**No optimization code without a strategy comparison first.** If you write optimization code before comparing at least 2 alternative approaches, you must delete it and start with this skill.

## When to Use

- Bootstrap phase: after baseline benchmark, before writing PRD
- When the optimization direction is unclear from hotspot analysis alone
- When hardware ceiling analysis reveals multiple possible approaches

## Process

### Step 1: Understand the Hotspot

Read the target C source file identified by the baseline benchmark. Answer:
- What is the current algorithm? (linear scan, binary search, lookup table, etc.)
- What is the memory access pattern? (strided, contiguous, random)
- What limits performance? (compute bound vs memory bandwidth bound)
- Is SIMD already used? If so, which instruction set (SSE, AVX, NEON, SVE)?

### Step 2: Read the Hardware Ceiling

Read `analysis.json` > `hardware_ceiling`:
- If memory bandwidth bound: focus on data layout, prefetch, cache blocking
- If compute bound: focus on SIMD, instruction-level parallelism, algorithm change

### Step 3: Generate 2-3 Candidate Strategies

For each strategy, specify:
- **Name**: short label (e.g., "NEON 4-wide loop unrolling", "Lookup table + branch elimination")
- **Mechanism**: how it improves performance (2-3 sentences)
- **Expected gain**: % improvement estimate with reasoning
- **Risk**: what could go wrong (compilation issues, platform-specific behavior, test fragility)
- **Files touched**: exact file paths
- **Complexity**: low / medium / high

Construct strategies by considering these dimensions:
1. SIMD vectorization (NEON/SVE, prefer `NPY_SIMD` cross-platform abstractions)
2. Loop transformations (unrolling, fusion, interchange, tiling)
3. Memory access optimization (prefetch, alignment, data layout)
4. Algorithmic changes (branch elimination, lookup tables, approximation)

### Step 4: Recommend One Strategy

State which strategy you recommend and why. The recommendation should consider:
- Expected gain vs hardware ceiling (don't target impossible gains)
- Implementation complexity vs iteration budget
- Risk of regression on other platforms
- Alignment with NumPy codebase conventions

### Step 5: Write Design Doc

Save the strategy comparison to `{{RUNTIME_DIR}}/design.md`:

```markdown
# Optimization Design — [operator name]
- Date: YYYY-MM-DD
- Hardware ceiling: [ceiling_time_us] us ([bound_type])

## Strategy Comparison

### Strategy A: [name]
- Mechanism: ...
- Expected gain: X%
- Risk: ...
- Complexity: low/medium/high

### Strategy B: [name]
...

## Recommendation
[Selected strategy] — [1 sentence justification]
```

### Step 6: Proceed to PRD Generation

After the design doc is saved, invoke the PRD generation step of the bootstrap phase. The PRD's `userStories` should decompose the selected strategy into verifiable tasks.

## Red Flags

- **Never** skip to implementation without at least 2 strategies compared
- **Never** propose a strategy whose expected gain exceeds (ceiling_time / baseline_time - 1) × 100%
- **Never** suggest platform-specific assembly when `NPY_SIMD` abstractions exist
- **Never** design for hypothetical bottlenecks — base decisions on measured data
