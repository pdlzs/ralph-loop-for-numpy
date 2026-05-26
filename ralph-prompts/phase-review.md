# 阶段: Review — 评估整体进展

## 目标

所有任务已解决（passed、attempted 或 infeasible）。现在评估整体优化效果，决定是结束还是继续。

## 输入

- `{{TASK_FILE}}` — 查看所有任务的状态和实际效果
- `{{DECISIONS_FILE}}` — 查看所有决策历史，理解什么有效、什么无效
- `{{PROGRESS_FILE}}` — 查看进度和硬件信息
- state.json — 了解迭代计数和收敛状态（**只读，禁止修改**）
- `{{ANALYSIS_FILE}}` — 查看 hardware_ceiling、基线数据，以及 **`user_intent.end_goal`（验收标准）**

## 评估维度

**⚡ 在进入具体评估之前，先使用 `ralph-code-review` skill 对优化代码进行五维度审查（正确性、性能、平台安全、代码质量、测试验证）。审查结果中 Critical 和 Important 级别的问题必须在评估前解决。**

### 1. 目标达成度

**首要验收标准：user_intent.end_goal**

从 `{{ANALYSIS_FILE}}` 中读取 `user_intent.end_goal`，**这是 review 的最高优先级验收标准**。

逐一检查 `end_goal.targets` 中的每个目标：

| 目标类型 | 检查方法 | 达成条件 |
|---------|---------|---------|
| `relative_improvement` | 端到端基准对比，计算提升比例 | 提升比例 ≥ target_pct |
| `absolute_time` | 端到端基准对比，测量绝对耗时 | 当前耗时 ≤ target_value |
| `eliminate_regression` | 检查 baselinePerf.benchmarks 中所有 `regression: true` 的用例 | 所有退化用例 ratio ≤ 1.05 |
| `max_improvement` | 与 hardware_ceiling 对比 | 达到硬件极限（≤ 天花板 × 1.1） |

**如果所有 must_have 目标均已达成** → 走路径 A（目标达成）。
**如果存在未达成的 must_have 目标** → 优先走路径 C（继续优化），除非已达硬件极限。

**端到端对比**：

对 `baselinePerf.benchmark` 指定的基准测试，用当前代码（包含所有已提交的优化）跑一次完整的 ASV，与 prd.json 中的 `baselinePerf.time` 对比。

**⚡ 多用例场景使用 `ralph-parallel-agents` skill** 并行运行多个 `-b` benchmark，节省 review 时间。

**性能比例计算**：

- 单用例: `Ratio = (baseline_time / current_time) × 100%`
- 多用例: `Ratio = GeometricMean(baseline_time_i / current_time_i) × 100%`

多用例必须使用**几何平均数**，不能使用算术平均数。计算方法：
```python
import math
ratios = [baseline_i / current_i for baseline_i, current_i in zip(baselines, currents)]
geo_mean = math.exp(sum(math.log(r) for r in ratios) / len(ratios))
ratio_pct = geo_mean * 100
```

将基准测试结果和 Ratio 计算写入 progress.txt 的 review 章节。

**与硬件天花板对比**：

读取 analysis.json 中的 `hardware_ceiling.ceiling_time_us`，将当前性能与天花板对比：
- 如果当前时间 ≤ 天花板 × 1.1 → 已达硬件极限
- 如果当前时间 > 天花板 × 1.5 → 仍有显著优化空间

### 2. 组合效果评估

**不要仅看单个 attempted 任务就判定方向失败**。检查：
- 是否有多个 attempted 任务具有 `dependsOn` 依赖关系，组合起来可能产生效果？
- 是否有"实现函数"（attempted）+"连接 dispatch"（attempted）的组合，单独无效果但组合后有效？
- 对于这种组合，如果所有前置任务代码仍保留在 git 中，考虑重新运行组合基准测试

### 3. 剩余优化空间

- 是否存在已修改代码引入的新热点
- 是否存在之前因依赖未解决而现在可行的方向
- 是否存在尚未探索的优化维度（如之前只做了 SIMD，未尝试缓存优化）
- 每个候选方向的预期收益是否 > hardware_ceiling 与当前性能之间的差距

### 4. 投入产出比

- 已消耗的迭代次数 vs 获得的性能提升
- 剩余方向的预期收益是否值得继续（预期收益 <5% 的方向不值得新增任务）

## 决策

**⚡ 在做出任何决策（路径 A/B/C）之前，必须完成 `ralph-verification` skill 的 Loop-Level Verification checklist。该 checklist 确保端到端基准对比、目标达成度检查、决策路径验证、COMPLETE 前置条件全部满足。**

### 决策优先级

**end_goal 优先于 hardware_ceiling**：先检查 `user_intent.end_goal`，再检查硬件天花板。

1. **先问**：`user_intent.end_goal` 中的所有 must_have 目标是否已达成？
2. **再问**：是否已达硬件极限？
3. **最后问**：是否有剩余优化空间？

### 路径 A: 目标已达成 → 标记完成

**触发条件**：`user_intent.end_goal` 中所有 must_have 目标均已满足（见上方目标达成度表格）。

在 `{{PROGRESS_FILE}}` 末尾追加:
```
<promise>COMPLETE</promise>

## 优化总结
- 用户目标: <引用 end_goal.description>
- 目标达成情况: <逐条说明每个 target 的达成状态>
- 累计性能提升: X%
- 成功任务: N 个
- 最终性能: X ms (基线: Y ms, 提升: Z%)
- 结束原因: 达成用户优化目标
```

### 路径 B: 已达优化极限 → 标记完成

**触发条件**：当前性能已接近硬件天花板（≤天花板 × 1.1），或所有可行方向都已尝试且剩余方向预期收益不足 5%。**如果 end_goal 中仍有 must_have 目标未达成但已达硬件极限，也走此路径并如实记录。**

- 在 `{{PROGRESS_FILE}}` 中记录 "已达当前硬件/算法优化极限"
- 追加 `<promise>COMPLETE</promise>` 和优化总结（包含与 hardware_ceiling 的对比数据）
- **必须说明**哪些 end_goal 目标未达成及其原因（硬件限制）

### 路径 C: 目标未达成 / 仍有优化空间 → 生成新任务

**触发条件**：
1. `user_intent.end_goal` 中存在未达成的 must_have 目标，且未达硬件极限；或
2. 当前性能 > 天花板 × 1.5，且发现新的、有实质价值的优化机会（预期收益 >5% 且不与已尝试方向重复）

**生成新任务时**：
1. **优先针对未达成的 end_goal**：新任务的方向应直接服务于缩小当前性能与 end_goal 之间的差距
2. 在 `{{TASK_FILE}}` 的 userStories 数组中追加新任务（格式同 bootstrap）
3. 在 `{{PROGRESS_FILE}}` 中记录 Review 发现

### Review 上限

环境变量 `RALPH_MAX_REVIEWS` 限制了 review 阶段的执行次数（脚本层面执行，默认 3 次）。你不需要直接检查此变量，但请注意：
- 每次 review 都是宝贵的决策机会
- 如果 end_goal 仍未达成，应在新任务中优先选择**预期收益最大**的方向
- 避免生成微小改进（<5%）的任务浪费 review 机会

## 重要约束

- **end_goal 是最高优先级验收标准**：先于 hardware_ceiling 检查
- **不要**在没有对比 end_goal 的情况下直接走路径 B
- **不要**生成与已标记 attempted/infeasible 任务本质相同的新任务
- **不要**在没有运行新的热点分析的情况下生成"微调"类任务
- **不要**设置 COMPLETE 后又添加新任务——两者互斥
- 如果连续 2 次 review 都未生成有效新任务（新 pending 数 = 0），本次 review **必须**选择路径 A 或 B
- 硬件物理限制（如内存带宽瓶颈、指令延迟硬限制）是合理的结束理由，但必须先如实记录 end_goal 达成情况
- **不要修改 state.json** — 阶段转换由脚本管理，AI 只追加 `<promise>COMPLETE</promise>` 到 progress.txt

## 完成自检

完成 review 后，验证：

- [ ] 已读取 `analysis.json` 中的 `user_intent.end_goal` 并逐条检查
- [ ] end_goal 达成情况已写入 progress.txt（每个 target 的达成状态）
- [ ] progress.txt 中追加的 review 记录使用了 GeometricMean 公式（多用例场景）
- [ ] progress.txt 中包含了与 hardware_ceiling 的对比数据
- [ ] 如果选择了路径 B 且 end_goal 未达成，已记录未达成原因（硬件限制）
- [ ] 如果选择了路径 C，新任务的 expectedImprovement 在 5%-30% 之间
- [ ] 如果选择了路径 C，新任务直接服务于未达成的 end_goal 目标
- [ ] **没有修改 state.json**
- [ ] decisions.jsonl 中追加的 review 记录是独立可解析的单行 JSON