# 阶段: Execute — 执行单个优化任务

## 目标

从 prd.json 中选择优先级最高的 pending 任务，实现优化，验证，记录结果。

## 步骤

### 0. 选择并锁定任务

读取 `{{TASK_FILE}}`，找到 status 为 "pending" 且 priority 最高的任务。将该任务的 status 设为 "in_progress"，写回 prd.json。

**重要**: 在开始之前，检查 `{{DECISIONS_FILE}}` 中最近 10 条记录。如果发现同一优化方向（相同 action）已标记为 "failed" 或 "rolled_back"，且你没有**实质性不同的新方案**，则：
- 将此任务标记为 "attempted"
- 在 reason 中说明 "方向已尝试且当前无新方案"
- 选择下一个 pending 任务

**依赖检查**: 如果该任务的 `dependsOn` 字段不为 null，检查所有前置任务的状态。如果所有前置任务均为 "passed"，正常执行。如果前置任务中有 "attempted" 或 "infeasible"，评估当前任务单独执行是否仍有独立价值。如果前置任务均未完成且当前任务单独执行无法产生可测量的改进（<2%），跳过此任务，选择下一个 pending 任务。

### 1. 阅读源码

阅读任务中 `files` 字段指定的源码文件，理解当前的实现逻辑和数据结构。

### 2. 实现优化

**⚡ 使用 `ralph-tdd-optimization` skill** 遵循 Benchmark-Driven Development 流程。

在修改任何 C 源码之前：
1. **先运行基线 benchmark**，确认当前性能数值（获取 `perf_before`）
2. 确认 benchmark 能正常运行（如果跑不通，"test" 本身有问题，不要动代码）
3. 实施**最小化优化** — 只做一个方向的改动，不捆绑无关修改

对目标代码实施优化。遵循 NumPy 代码风格，保持变更最小化。

### 3. 验证

**必须严格按顺序执行三步验证，不可跳过任何一步。**

**⚡ 如果任何一步失败，立即使用 `ralph-systematic-debugging` skill 进行根因分析**，不要猜测式修复。

```bash
# 步骤 1: 编译
pip install --no-build-isolation -e .

# 步骤 2: 测试（针对修改模块）
python -m pytest numpy/core/tests/ -x -q

# 步骤 3: 基准测试
# ⚠️ 必须遵守 system.md 的 ASV 命令规范：
# - 只用 -b "完整名(精确参数)" 形式
# - 绝对禁止用 --bench 或 grep/awk/tail/head 管道过滤
# - 用 prd.json 中 baselinePerf.benchmark 的精确值作为 -b 参数
cd benchmarks && asv run --python=same -b "<baselinePerf.benchmark>"
```

### 4. 判断结果

根据任务 `type` 字段，使用不同的判断规则：

**对于 type = "optimization" 的任务**：

| 场景 | 操作 |
|------|------|
| 性能提升 ≥2% 且测试通过 | status: "passed"，result: "passed" |
| 性能变化 <2%（不显著）| status: "attempted"，result: "attempted"，在 notes 中说明原因 |
| 性能退化 ≥2% 但 <10%，代码正确 | status: "attempted"，回滚代码，result: "rolled_back" |
| 性能退化 ≥10% | 回滚代码，status: "attempted"，result: "rolled_back" |
| 编译或测试失败 | 修复后重试；若无法修复则回滚，status: "attempted"，result: "rolled_back" |

**对于 type = "refactoring" 的任务**：

| 场景 | 操作 |
|------|------|
| 代码结构改善且测试通过 | status: "passed"，actualImprovement: 0 |
| 编译或测试失败 | 修复后重试；若无法修复则回滚，status: "attempted" |

**对于有 dependsOn 且前置任务未完成的 optimization 任务**：
- 单独执行时基准测试提升可能 <2%，这是预期行为
- 标记为 status: "attempted"，但 notes 中必须写明："前置任务 OPT-00X 未完成，当前效果未体现，待前置任务完成后组合评估"
- **不要**因为单独效果 <2% 就判定此任务方向无效

### 5. 记录结果

**⚡ 使用 `ralph-code-review` skill 的 Self-Review Checklist 进行快速自审**，确认以下所有项后再记录结果。

**更新 prd.json 中该任务**:
- `status`: "passed" 或 "attempted"
- `actualImprovement`: 实际性能变化百分比（正数=提升，负数=退化）
- `attemptCount`: 递增
- `lastAttemptIter`: 当前迭代号

**追加到 decisions.jsonl**（一行 JSON，**绝对不能两行合并**）:
```json
{"iter": {{ITER_NUM}}, "phase": "execute", "task_id": "OPT-XXX", "action": "简述优化方向", "result": "passed|attempted|rolled_back", "perf_before": X, "perf_after": Y, "perf_change_pct": Z, "reason": "一句话说明关键发现"}
```

**追加到 progress.txt**（使用以下统一中文格式，**不要混用英文**）:
```
## [当前时间] - 迭代 {{ITER_NUM}}

### 任务: [任务ID] - [标题]
- **状态**: [passed/attempted]
- **性能变化**: +X% / -X% / 无显著变化
- **修改文件**: [文件列表]

### 做了什么
[2-3句话简述]

### 关键发现
- [对后续优化有参考价值的发现]
```

### 6. 提交代码

如果代码有变更且验证通过（无论 passed 还是 attempted），提交到 git:
```bash
git add <修改的文件>
git commit -m "PERF: <简短描述>"
```

如果代码已回滚，不需要提交。

## 注意

- 每轮只执行一个任务。不要在一次调用中执行多个任务。
- 如果任务涉及大改动，拆成子步骤逐步提交，但仍在一次 AI 调用中完成。
- 不要在未运行基准测试的情况下标记 "passed"。
- **不要修改 state.json** — 阶段转换和迭代计数由脚本管理。

## 完成自检

完成所有步骤后，验证：

- [ ] prd.json 中当前任务的 status 不是 "pending" 或 "in_progress"
- [ ] prd.json 中当前任务的 actualImprovement 和 attemptCount 已更新
- [ ] decisions.jsonl 最后一行是独立可解析的 JSON（用 python3 验证）
- [ ] progress.txt 追加了本次迭代记录（中文格式）
- [ ] git status 中没有 runtime/ 目录下的文件