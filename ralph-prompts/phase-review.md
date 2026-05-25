# 阶段: Review — 评估整体进展

## 目标

所有任务已解决（passed、attempted 或 infeasible）。现在评估整体优化效果，决定是结束还是继续。

## 输入

- `{{TASK_FILE}}` — 查看所有任务的状态和实际效果
- `{{DECISIONS_FILE}}` — 查看所有决策历史，理解什么有效、什么无效
- `{{PROGRESS_FILE}}` — 查看进度和硬件信息
- state.json — 了解迭代计数和收敛状态（**只读，禁止修改**）
- `{{ANALYSIS_FILE}}` — 查看 hardware_ceiling 和基线数据

## 评估维度

### 1. 目标达成度

**端到端对比**：

对 `baselinePerf.benchmark` 指定的基准测试，用当前代码（包含所有已提交的优化）跑一次完整的 ASV，与 prd.json 中的 `baselinePerf.time` 对比。

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

### 路径 A: 目标已达成 → 标记完成

在 `{{PROGRESS_FILE}}` 末尾追加:
```
<promise>COMPLETE</promise>

## 优化总结
- 累计性能提升: X%
- 成功任务: N 个
- 最终性能: X ms (基线: Y ms, 提升: Z%)
- 结束原因: 达成优化目标
```

### 路径 B: 已达优化极限 → 标记完成

如果当前性能已接近硬件天花板（≤天花板 × 1.1），或所有可行方向都已尝试且剩余方向预期收益不足 5%:
- 在 `{{PROGRESS_FILE}}` 中记录 "已达当前硬件/算法优化极限"
- 追加 `<promise>COMPLETE</promise>` 和优化总结（包含与 hardware_ceiling 的对比数据）

### 路径 C: 仍有优化空间 → 生成新任务

如果当前性能 > 天花板 × 1.5，且发现新的、有实质价值的优化机会（预期收益 >5% 且不与已尝试方向重复）:

1. 在 `{{TASK_FILE}}` 的 userStories 数组中追加新任务:
```json
{
  "id": "OPT-<下一个编号>",
  "title": "...",
  "description": "...",
  "priority": <当前最大优先级 + 1>,
  "status": "pending",
  "type": "optimization",
  "files": ["..."],
  "acceptanceCriteria": ["..."],
  "expectedImprovement": ">5% 且 ≤30%",
  "dependsOn": null,
  "attemptCount": 0,
  "lastAttemptIter": null,
  "actualImprovement": null,
  "notes": ""
}
```

2. 在 `{{PROGRESS_FILE}}` 中记录:
```
## Review 发现
- 新热点: [描述]
- 新增任务: [任务ID列表]
- Review 时间: [当前时间]
```

## 重要约束

- **不要**生成与已标记 attempted/infeasible 任务本质相同的新任务
- **不要**在没有运行新的热点分析的情况下生成"微调"类任务
- **不要**设置 COMPLETE 后又添加新任务——两者互斥
- 如果连续 2 次 review 都未生成有效新任务（新 pending 数 = 0），本次 review **必须**选择路径 A 或 B
- 硬件物理限制（如内存带宽瓶颈、指令延迟硬限制）是合理的结束理由
- **不要修改 state.json** — 阶段转换由脚本管理，AI 只追加 `<promise>COMPLETE</promise>` 到 progress.txt

## 完成自检

完成 review 后，验证：

- [ ] progress.txt 中追加的 review 记录使用了 GeometricMean 公式（多用例场景）
- [ ] progress.txt 中包含了与 hardware_ceiling 的对比数据
- [ ] 如果选择了路径 B，记录了"已达硬件/算法优化极限"和天花板数据
- [ ] 如果选择了路径 C，新任务的 expectedImprovement 在 5%-30% 之间
- [ ] **没有修改 state.json**
- [ ] decisions.jsonl 中追加的 review 记录是独立可解析的单行 JSON