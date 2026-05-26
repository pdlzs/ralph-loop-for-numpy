# 阶段: Bootstrap — 分析与 PRD 生成

## 目标

分析优化目标，测量基线性能，生成结构化的性能需求文档（prd.json）。

## 用户目标

{{USER_GOAL}}

## 步骤

### 0. 识别用户意图（优先执行）

**在运行任何基准测试之前**，先从 `{{USER_GOAL}}` 中提取用户意图，写入 `{{RUNTIME_DIR}}/analysis.json` 的 `user_intent` 字段。

需要识别三个维度：

#### 0.1 用例范围 (use_case_scope)

用户关注的 benchmark 名称、算子、数据类型、参数范围。如果是模糊描述（"优化 searchsort"），列出所有相关 benchmark 用例。如果用户指定了精确 benchmark 名，原样记录。

```json
"use_case_scope": {
  "summary": "一句话概括优化范围",
  "benchmarks": ["精确的 benchmark 名称列表"],
  "operators": ["涉及的算子"],
  "dtypes": ["涉及的数据类型"],
  "parameters": "参数范围说明"
}
```

#### 0.2 结束目标 (end_goal)

这是 **review 阶段的验收标准**。从用户 prompt 中提取可测量的目标：

- 如果用户说"提升 X%"→ `type: "relative_improvement"`, `target_pct: X`
- 如果用户说"达到 XX ms" → `type: "absolute_time"`, `target_value: XX`, `unit: "ms"`
- 如果用户说"消除退化" → `type: "eliminate_regression"`, `target_regression_free: true`
- 如果用户只说"优化"而无具体数值 → `type: "max_improvement"`, 意为尽力优化到硬件极限
- 如果用户有多重目标组合 → 全部写入 `targets` 数组

```json
"end_goal": {
  "description": "用户原文中的目标描述",
  "targets": [
    {
      "type": "relative_improvement|absolute_time|eliminate_regression|max_improvement",
      "target_pct": 20,
      "target_value": null,
      "unit": null,
      "applies_to": "all|benchmark_name"
    }
  ],
  "priority": "must_have|nice_to_have"
}
```

#### 0.3 其他约束 (other)

用户提到的技术偏好、平台约束、风险规避等：

```json
"other": {
  "techniques": ["优先使用的技术，如 NEON SIMD"],
  "constraints": ["硬约束，如 不修改公共 API", "保持 ABI 兼容"],
  "risk_avoidance": ["需要规避的风险"],
  "notes": "其他值得注意的信息"
}
```

**完整 user_intent 写入示例**：

```json
{
  "user_intent": {
    "use_case_scope": {
      "summary": "优化 binary ufunc 的浮点运算性能",
      "benchmarks": ["bench_ufunc_strides.BinaryFP.time_binary\\(<ufunc 'fmax'>, 1, 1, 1, 'd'\\)"],
      "operators": ["fmax", "fmin"],
      "dtypes": ["float32", "float64"],
      "parameters": "连续内存，stride=1"
    },
    "end_goal": {
      "description": "整体性能提升 20%",
      "targets": [{"type": "relative_improvement", "target_pct": 20, "applies_to": "all"}],
      "priority": "must_have"
    },
    "other": {
      "techniques": ["NPY_SIMD 跨平台抽象", "循环展开"],
      "constraints": ["不修改公共 API", "保持 ABI 兼容"],
      "risk_avoidance": ["避免仅适用于单平台的优化"],
      "notes": ""
    }
  }
}
```

**⚠️ 这一步的输出将作为 review 阶段的验收标准。如果用户目标模糊，尽量推断并记录，避免 review 时无法判断是否达成目标。**

### 1. 运行基线基准测试

从用户目标中提取 benchmark 名称，用 `-b "精确名称"` 运行 ASV 基准测试（命令格式见 system.md 的 ASV 规范）。

**并行加速**：如果有 3 个以上的独立 benchmark，使用 `ralph-parallel-agents` skill 派发多个子代理并行运行基准测试，将耗时缩短至 1/N。

### 2. 分析热点

- 阅读相关 C 源码，理解算法和数据流
- 识别关键热点：循环结构、分支模式、内存访问模式
- 检查当前 SIMD 利用情况
- 分析缓存行为（是否 cache-friendly）

**并行加速**：如果热点分析涉及多个独立源文件，使用 `ralph-parallel-agents` skill 并行分析，每个子代理专注一个文件。

### 3. 计算硬件性能天花板

**必须先完成此步骤，再设定优化目标。**

在设定 targetPerf 之前，先计算当前硬件的物理极限：
- 内存带宽极限：数据量 × 3（两个输入 + 一个输出） / 实测带宽 = 带宽理论最小时间
- 计算极限：数据量 × 操作延迟 / SIMD宽度 × 并行度 = 计算理论最小时间
- 取两者中较大的值作为硬件天花板

将天花板写入 analysis.json 的 `hardware_ceiling` 字段：
```json
{
  "hardware_ceiling": {
    "memory_bandwidth_bound": {"time_us": X, "description": "数据搬运最小时间"},
    "compute_bound": {"time_us": Y, "description": "计算最小时间"},
    "dominant_bound": "memory_bandwidth|compute",
    "ceiling_time_us": Z,
    "ceiling_explanation": "一句话说明哪个瓶颈主导"
  }
}
```

**targetPerf.time 不得低于 hardware_ceiling.ceiling_time_us × 0.9**（留 10% 余量考虑测量误差）。如果用户目标要求的天花板以下提升，targetPerf 应自动调整为天花板附近。

### 4. 研究优化方向

**⚡ 使用 `ralph-brainstorming` skill** 进行系统化的方案对比。

搜索业界优化方案，考虑以下维度：
- SIMD 向量化机会（NEON/SVE，优先使用 NPY_SIMD 跨平台抽象）
- 循环变换（展开、融合、交换、分块）
- 内存访问优化（预取、对齐、数据布局）
- 算法级优化（分支消除、查表替代计算、近似算法）

**必须完成以下步骤再进入 PRD 生成**：

1. 生成 **2-3 个候选优化策略**，每个策略写明：机制、预期收益、风险、复杂度
2. 与 `hardware_ceiling` 对比，过滤掉不可能的策略（预期收益超天花板）
3. **推荐一个策略**，说明理由
4. 将策略对比写入 `{{RUNTIME_DIR}}/design.md`（格式见 ralph-brainstorming skill）

### 5. 生成 prd.json

创建 `{{RUNTIME_DIR}}/prd.json`，格式：

```json
{
  "project": "<算子>-optimization",
  "branchName": "ralph/<算子>-opt",
  "description": "...",
  "baselinePerf": {
    "time": X,
    "unit": "ms",
    "benchmark": "最严重退化的单个benchmark完整名",
    "measured_at": "...",
    "benchmarks": [
      {"benchmark": "完整benchmark名", "before": Y1, "after": Y2, "ratio": R, "regression": true/false}
    ]
  },
  "targetPerf": {"time": Y, "improvement": "Z%"},
  "userStories": [...]
}
```

**`baselinePerf.benchmarks` 数组说明**：
- 将用户原始目标中列出的**所有 benchmark 用例**逐条写入此数组
- `before` 和 `after` 分别是基线版本和当前版本的性能数值（单位与 `baselinePerf.unit` 一致）
- `ratio` 是 after/before 的比值（>1 表示退化，<1 表示改进）
- `regression` 为 true 表示当前版本比基线退化（ratio > 1.05）
- 这个数组用于 `show_status` 展示完整的退化列表，因此必须**包含所有用户关注的用例**，不能只写最严重的一个

每个 userStory：
```json
{
  "id": "OPT-00N",
  "title": "简短标题",
  "description": "具体做什么",
  "priority": N,
  "status": "pending",
  "type": "optimization|refactoring|infrastructure",
  "files": ["numpy/core/src/..."],
  "acceptanceCriteria": ["可测量的验收条件"],
  "expectedImprovement": "X%",
  "dependsOn": ["OPT-00M"] 或 null,
  "attemptCount": 0,
  "lastAttemptIter": null,
  "actualImprovement": null,
  "notes": ""
}
```

**任务设计铁律**：
- 每个任务可在单次迭代中完成（不超过 2-3 个文件的修改）
- 3-8 个任务为宜，按优先级排序：容易且高收益的排前面
- `expectedImprovement` **硬约束**：必须是 **5%-30%** 之间的数值，绝对不可超过 30%。如果预期收益超过 30%，必须拆分为多个子任务
- 优先拆分"大的改动"为多个可独立验证的子任务
- `acceptanceCriteria` 必须是可测量的（如 "benchmark 提升 ≥10%"）
- **依赖声明**：如果一个任务的效果只有在前置任务完成后才能体现（如"实现函数"需要后续"连接 dispatch"才能生效），用 `dependsOn` 字段声明前置任务 ID。这类任务的 `expectedImprovement` 应标注为 "depends on OPT-00X"，单独执行时的基准测试提升可能 <2%，但在前置任务完成后应重新评估组合效果
- `type` 为 `refactoring` 的任务，`expectedImprovement` 应为 "0%"（纯重构无性能预期），其 `acceptanceCriteria` 应围绕代码结构而非性能

### 6. 记录硬件信息

在 `{{PROGRESS_FILE}}` 中找到「硬件能力汇总」章节（由脚本模板创建），**填充该章节的内容**（不要删除章节标题或覆盖整个文件）。记录：
- CPU 架构和 SIMD 能力（包括支持的指令集如 SVE/NEON/SSE 等）
- 编译器版本
- 关键硬件约束（如缓存大小、实测内存带宽）
- 硬件性能天花板（引用 analysis.json 中的 hardware_ceiling）

同时填充「经验能力汇总」章节，初始内容为"待迭代中逐步补充"。

### 7. 任务命名

选择一个简洁的英文任务名（如 opt_searchsort_neon），写入 `{{RUNTIME_DIR}}/.task_name`。
仅包含小写字母、数字和下划线，不超过 64 个字符。

## 输出验证清单

完成所有步骤后，逐项验证：

- [ ] `{{RUNTIME_DIR}}/analysis.json` — 有效 JSON，包含 `user_intent` 字段（用例范围、结束目标、其他约束）
- [ ] `{{RUNTIME_DIR}}/analysis.json` — `user_intent.end_goal` 包含可测量的验收标准
- [ ] `{{RUNTIME_DIR}}/analysis.json` — 有效 JSON，包含 hardware_ceiling 字段
- [ ] `{{RUNTIME_DIR}}/prd.json` — 有效 JSON，包含 baselinePerf、targetPerf、userStories
- [ ] `{{RUNTIME_DIR}}/prd.json` — baselinePerf.benchmarks 数组包含用户原始目标中的所有关注用例
- [ ] `{{RUNTIME_DIR}}/prd.json` — 所有 expectedImprovement 在 5%-30% 之间（refactoring 类型为 0%）
- [ ] `{{RUNTIME_DIR}}/prd.json` — targetPerf.time ≥ hardware_ceiling.ceiling_time_us × 0.9
- [ ] `{{RUNTIME_DIR}}/prd.json` — targetPerf 与 user_intent.end_goal 方向一致（如用户要求 20% 提升，targetPerf 应 ≥ 20%）
- [ ] `{{RUNTIME_DIR}}/prd.json` — 有依赖关系的任务已声明 dependsOn
- [ ] `{{RUNTIME_DIR}}/progress.txt` — 硬件能力汇总章节已被填充（不是空占位符）
- [ ] `{{RUNTIME_DIR}}/.task_name` — 内容为合法任务名