---
name: ralph-parallel-agents
description: Use during bootstrap phase for parallel baseline benchmarking, hotspot analysis, and hardware detection. Dispatch multiple independent sub-agents simultaneously. Triggers when multiple independent analysis tasks can run concurrently.
---

# Ralph Parallel Agents — Concurrent Analysis Dispatch

Adapted from Superpowers' dispatching-parallel-agents skill. Used to parallelize independent analysis work during Ralph Loop's bootstrap and review phases.

## When to Use

**Bootstrap phase** — parallelize:
- Baseline ASV benchmarks (multiple `-b` targets)
- C source hotspot analysis (multiple files)
- CPU feature detection + hardware ceiling calculation

**Review phase** — parallelize:
- Multiple benchmark comparisons for end-to-end evaluation
- Independent code review dimensions (if reviewers are dispatched)

**Do NOT use** when:
- Tasks share state or have sequential dependencies
- Results of one task determine the inputs of another
- Git worktree isolation is needed between tasks

## Process

### Step 1: Identify Independent Analysis Tasks

Group work into independent domains. Each domain must:
- Have no shared mutable state with other domains
- Produce a single, clear output (JSON file, stdout report, etc.)
- Be completable without context from other domains

Example bootstrap decomposition:
```
Agent 1: Run ASV baseline for benchmark set A (3 benchmarks)
Agent 2: Run ASV baseline for benchmark set B (3 benchmarks)
Agent 3: Analyze C source hotspots in numpy/core/src/<module>/
Agent 4: Detect CPU features + calculate hardware ceiling
```

### Step 2: Create Focused Agent Prompts

Each sub-agent prompt must contain:
1. **Exact goal**: what output to produce
2. **Exact commands**: what to run, with full parameters
3. **Output format**: expected structure (file path, JSON schema, etc.)
4. **Constraints**: what NOT to do (don't modify code, don't commit, etc.)

Example:
```
Goal: Run ASV baseline for benchmarks A, B, C and write results to /tmp/baseline_a.json

Commands to run:
  cd benchmarks && asv run --python=same -b "exact_name_A" -b "exact_name_B" -b "exact_name_C"

Output: Write JSON to /tmp/baseline_a.json with format:
  {"benchmarks": [{"name": ..., "time": ...}, ...]}

Constraints:
  - Do NOT modify any source files
  - Do NOT run git commands
  - Do NOT run tests (this is benchmark-only)
  - Only use exact -b parameters provided above
```

### Step 3: Dispatch in Parallel

Use the Agent tool with `subagent_type: "general-purpose"` for each task. Dispatch all in a single message so they run concurrently.

### Step 4: Collect and Integrate

After all agents complete:
1. Read each agent's output
2. Check for conflicts or inconsistencies between results
3. Merge into the appropriate Ralph Loop state files:
   - Benchmark results → `prd.json` > `baselinePerf.benchmarks`
   - Hotspot analysis → `analysis.json` > `hotspots`
   - Hardware info → `analysis.json` > `hardware_ceiling`

## Key Benefits for Ralph Loop

- **Bootstrap time reduction**: 4 sequential analysis steps → 1 parallel dispatch
- **Fresh context per agent**: each agent sees only what it needs, reducing confusion
- **Independent verification**: results from one agent can cross-validate another

## Red Flags

- Never dispatch agents that modify the same file
- Never dispatch agents that depend on each other's output
- Never provide incomplete benchmark names (agents must use exact `-b` parameters)
- Always verify each agent's output before integrating — don't blindly merge
