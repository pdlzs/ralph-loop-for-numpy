# Ralph Loop — NumPy 自适应性能优化代理

Ralph Loop 是一个 Shell 驱动的 AI 代理循环，用于 NumPy C 扩展的性能优化。它在三阶段循环中编排 AI（Claude Code / OpenCode）：**分析 → 优化 → 审查**，脚本负责状态流转与收敛控制，AI 负责代码分析、优化实施和结果记录。

## 前置依赖

- **jq** — JSON 处理（`apt install jq`）
- **Python 3** — 模板渲染和 JSON 验证
- **AI 工具** — 以下之一：
  - [Claude Code](https://docs.anthropic.com/en/docs/claude-code)（`npm install -g @anthropic-ai/claude-code`）
  - [OpenCode](https://github.com/anomalyco/opencode)（`npm install -g opencode-ai@latest`）

## 快速开始

```bash
# 1. 赋予执行权限
chmod +x ralph-loop.sh

# 2. 启动新的优化任务
./ralph-loop.sh -p "优化 searchsort 算子的 NEON 向量化" -i 15

# 3. 继续已有任务（使用更多迭代）
./ralph-loop.sh -n opt_searchsort -i 10
```

## 命令参考

```bash
./ralph-loop.sh [命令] [选项]
```

### 命令

| 命令 | 说明 |
|------|------|
| `status` | 列出所有任务，或查看指定任务详情 |
| `clean -n <任务名>` | 删除指定任务的运行时文件 |

### 选项

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `-p, --prompt TEXT` | 优化目标描述（启动新任务时使用） | — |
| `-n, --task-name NAME` | 任务名，用于继续已有任务或命名新任务 | 自动生成 |
| `-i, --max-iter N` | 最大迭代次数 | 20 |
| `-t, --tool TOOL` | AI 工具：`claude` 或 `opencode` | 自动检测 |
| `-h, --help` | 显示帮助 | — |

### 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `RALPH_TOOL` | 默认 AI 工具 | 自动检测 |
| `RALPH_MAX_ITERATIONS` | 全局最大迭代次数 | 20 |
| `RALPH_MAX_TASK_ATTEMPTS` | 单任务最大尝试次数 | 3 |
| `RALPH_PROMPTS_DIR` | 提示词目录路径 | `./ralph-prompts` |

## 示例

```bash
# 列出所有任务
./ralph-loop.sh status

# 查看指定任务的详细状态
./ralph-loop.sh status -n opt_searchsort

# 清理某个任务的运行时数据
./ralph-loop.sh clean -n opt_searchsort

# 启动新任务：指定优化目标和最大迭代次数
./ralph-loop.sh -p "优化 ufunc 循环中的 SIMD 利用" -i 10

# 继续已有任务（追加迭代）
./ralph-loop.sh -n opt_searchsort -i 5

# 显式指定 AI 工具
./ralph-loop.sh -n opt_searchsort -t claude -i 10

# 指定任务名（不自动生成）
./ralph-loop.sh -n opt_binary_ufunc -p "优化二元 ufunc 的 fmax/fmin 实现"
```

## 工作流程

```
bootstrap → execute → execute → ... → review → execute → ... → done
```

### 阶段 1：Bootstrap（分析与规划）

AI 根据用户目标执行基线基准测试、分析 C 源码热点、计算硬件性能天花板、研究优化方向，然后生成结构化的 `prd.json`。

**输出：**
- `runtime/<任务名>/prd.json` — 性能需求文档（含基线数据、目标、任务列表）
- `runtime/<任务名>/analysis.json` — 硬件天花板分析
- `runtime/<任务名>/progress.txt` — 硬件能力汇总

### 阶段 2：Execute（执行优化）

AI 按优先级从 prd.json 中选择 pending 任务，实施代码优化，然后依次执行**编译 → 测试 → 基准测试**三步验证。结果记录到 decisions.jsonl 和 progress.txt。

每个任务的验证不得跳过任何一步：
1. `pip install --no-build-isolation -e .` — 编译
2. `python -m pytest numpy/core/tests/ -x -q` — 测试
3. ASV 基准测试（使用精确 `-b` 参数）

### 阶段 3：Review（审查与决策）

当所有任务已尝试后，AI 评估整体效果，决定以下三条路径之一：
- **路径 A**：目标达成 → 标记 `COMPLETE`
- **路径 B**：已达硬件极限 → 标记 `COMPLETE` 并记录天花板数据
- **路径 C**：仍有优化空间 → 生成新任务，继续循环

### 收敛机制（脚本级）

脚本独立于 AI 执行客观收敛判断：

| 条件 | 行为 |
|------|------|
| AI 连续失败 N 次 | 强制终止 |
| progress.txt 超过大小上限 | 强制终止（保护上下文窗口） |
| 单任务重试超过上限 | 自动标记为 `infeasible` |
| 达到最大迭代次数 | 正常结束 |

## 运行时目录结构

```
runtime/
└── <任务名>/
    ├── prd.json          # 性能需求文档（AI 读写）
    ├── analysis.json     # 硬件天花板分析（AI 读写）
    ├── state.json        # 循环状态（脚本管理，AI 只读）
    ├── decisions.jsonl   # 结构化决策日志（AI 追加）
    ├── progress.txt      # 人类可读进度（AI 追加）
    └── log.txt           # 完整执行日志
```

## 任务状态说明

| 状态 | 含义 |
|------|------|
| `pending` | 待执行 |
| `in_progress` | 正在执行（当前迭代选中） |
| `passed` | 优化成功，性能提升达标 |
| `attempted` | 已尝试，效果不显著或已回滚 |
| `infeasible` | 超过最大尝试次数，放弃 |

## 注意事项

- **脚本管理 state.json**：AI 只读 state.json，阶段转换和计数值由脚本自动维护
- **Git 安全**：`runtime/` 目录自动加入 `.gitignore`，不会被提交到仓库
- **可恢复性**：中断后可以用 `-n <任务名>` 继续，脚本会跳过已完成的任务
- **ASV 命令规范**：基准测试必须使用精确的 `-b` 参数，禁止模糊匹配或管道过滤
- **多任务并行**：不同优化目标可以同时运行在各自的 `runtime/<任务名>/` 目录下
