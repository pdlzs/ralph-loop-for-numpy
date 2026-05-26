#!/bin/bash
# Ralph Loop v2.0 — NumPy 自适应性能优化 AI 代理循环
#
# 架构:
#   Shell 负责 → 阶段流转、状态验证、收敛判断、错误处理
#   AI 提示词 → ralph-prompts/ 目录，Shell 读取并注入变量后传给 AI
#
# 阶段:
#   bootstrap → execute → review → execute (循环) 或 done
#
# 用法:
#   ./ralph-loop.sh -p "优化 searchsort 算子" -i 10
#   ./ralph-loop.sh -n opt_searchsort -i 10
#   ./ralph-loop.sh -n opt_searchsort status
#   ./ralph-loop.sh -n opt_searchsort clean
set -e

# =============================================================================
# 路径 & 可调参数
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS_DIR="${RALPH_PROMPTS_DIR:-$SCRIPT_DIR/ralph-prompts}"
RUNTIME_BASE="$SCRIPT_DIR/runtime"

MAX_ITERATIONS="${RALPH_MAX_ITERATIONS:-20}"
MAX_TASK_ATTEMPTS="${RALPH_MAX_TASK_ATTEMPTS:-3}"
MAX_REVIEWS="${RALPH_MAX_REVIEWS:-3}"
CONVERGENCE_AI_FAILURES="${RALPH_CONVERGENCE_AI_FAILURES:-3}"
PROGRESS_MAX_KB="${RALPH_PROGRESS_MAX_KB:-1024}"

# =============================================================================
# 工具函数
# =============================================================================

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

log_info()  { echo "【RALPH】【$(timestamp)】$*"; }
log_warn()  { echo "【RALPH】【$(timestamp)】[WARN] $*" >&2; }
log_error() { echo "【RALPH】【$(timestamp)】[ERROR] $*" >&2; }

detect_ai_tool() {
    if command -v claude &> /dev/null; then
        echo "claude"
    elif command -v opencode &> /dev/null; then
        echo "opencode"
    else
        echo ""
    fi
}

run_ai() {
    # 调用 AI 工具，保存输出到日志，正确返回 AI 进程的退出码
    # claude 使用 stream-json 格式实现流式文本输出，仅提取 text_delta 实时显示
    local prompt="$1"
    local ai_exit=0

    log_info "--- AI 代理开始 (phase: $(read_state phase 2>/dev/null || echo '?')) ---"

    set +e
    if [ "$AI_TOOL" = "opencode" ]; then
        printf '%s\n' "$prompt" | IS_SANDBOX=1 opencode run --dangerously-skip-permissions 2>&1 | tee -a "$LOG_FILE"
        ai_exit=${PIPESTATUS[1]}
    elif [ "$AI_TOOL" = "claude" ]; then
        printf '%s\n' "$prompt" | IS_SANDBOX=1 claude --dangerously-skip-permissions -p --output-format stream-json --include-partial-messages 2>>"$LOG_FILE" | jq --unbuffered -rj 'select(.type == "stream_event" and .event.delta.type? == "text_delta") | .event.delta.text' | tee -a "$LOG_FILE"
        ai_exit=${PIPESTATUS[1]}
    else
        log_error "未找到 AI 工具 (claude/opencode)"
        ai_exit=1
    fi
    set -e

    log_info "--- AI 代理结束 (exit: $ai_exit) ---"
    return $ai_exit
}

# =============================================================================
# 状态文件管理 (state.json)
# =============================================================================

init_state() {
    if [ ! -f "$STATE_FILE" ]; then
        cat > "$STATE_FILE" << 'STEOF'
{
  "phase": "bootstrap",
  "iteration": 0,
  "current_task": null,
  "consecutive_ai_failures": 0,
  "review_count": 0
}
STEOF
    fi
}

read_state() {
    local key="$1"
    jq -r ".$key // empty" "$STATE_FILE" 2>/dev/null
}

write_state() {
    local key="$1"
    local value="$2"
    local tmp
    tmp=$(mktemp)
    jq ".$key = $value" "$STATE_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE_FILE" || {
        rm -f "$tmp"
        log_error "写入 state.json 失败: $key = $value"
    }
}

increment_state() {
    local key="$1"
    local current
    current=$(read_state "$key")
    [ -z "$current" ] && current=0
    write_state "$key" $((current + 1))
}

# =============================================================================
# 提示词加载
# =============================================================================

load_prompt() {
    local name="$1"
    local file="$PROMPTS_DIR/$name"

    if [ ! -f "$file" ]; then
        log_error "提示词文件不存在: $file"
        return 1
    fi

    # 使用 Python 做模板替换，通过环境变量传值，避免 shell 转义和多行字符串问题
    RALPH_WORK_DIR="$SCRIPT_DIR" \
    RALPH_RUNTIME_DIR="$RUNTIME_DIR" \
    RALPH_TASK_FILE="$TASK_FILE" \
    RALPH_DECISIONS_FILE="$DECISIONS_FILE" \
    RALPH_PROGRESS_FILE="$PROGRESS_FILE" \
    RALPH_STATE_FILE="$STATE_FILE" \
    RALPH_ANALYSIS_FILE="$ANALYSIS_FILE" \
    RALPH_LOG_FILE="$LOG_FILE" \
    RALPH_ITER_NUM="$(read_state iteration)" \
    RALPH_USER_GOAL="${INITIAL_PROMPT:-请根据代码分析自动确定优化目标}" \
    RALPH_TEMPLATE_FILE="$file" \
    python3 -c '
import os, sys
with open(os.environ["RALPH_TEMPLATE_FILE"]) as f:
    c = f.read()
c = c.replace("{{WORK_DIR}}",      os.environ["RALPH_WORK_DIR"])
c = c.replace("{{RUNTIME_DIR}}",   os.environ["RALPH_RUNTIME_DIR"])
c = c.replace("{{TASK_FILE}}",     os.environ["RALPH_TASK_FILE"])
c = c.replace("{{DECISIONS_FILE}}", os.environ["RALPH_DECISIONS_FILE"])
c = c.replace("{{PROGRESS_FILE}}", os.environ["RALPH_PROGRESS_FILE"])
c = c.replace("{{STATE_FILE}}",    os.environ["RALPH_STATE_FILE"])
c = c.replace("{{ANALYSIS_FILE}}", os.environ["RALPH_ANALYSIS_FILE"])
c = c.replace("{{LOG_FILE}}",      os.environ["RALPH_LOG_FILE"])
c = c.replace("{{ITER_NUM}}",      os.environ["RALPH_ITER_NUM"])
c = c.replace("{{USER_GOAL}}",     os.environ["RALPH_USER_GOAL"])
sys.stdout.write(c)
'
}

build_full_prompt() {
    local phase="$1"

    # 1. 系统提示词
    load_prompt "system.md"
    echo ""
    echo "---"
    echo ""

    # 2. 阶段提示词
    load_prompt "phase-${phase}.md"
    echo ""
    echo "---"
    echo ""

    # 3. 当前运行时上下文
    echo "## 运行时上下文"
    echo "- 工作目录: $SCRIPT_DIR"
    echo "- 运行时目录: $RUNTIME_DIR"
    echo "- 阶段: $phase"
    echo "- 迭代: $(read_state iteration) / $MAX_ITERATIONS"
    echo "- 连续 AI 失败: $(read_state consecutive_ai_failures)"
    echo ""

    # 4. 执行阶段才注入当前任务和决策历史
    if [ "$phase" = "execute" ]; then
        echo "## 当前任务"
        local task
        task=$(get_next_task)
        if [ -n "$task" ] && [ "$task" != "null" ]; then
            echo "$task" | jq -r '"ID: \(.id)\n标题: \(.title)\n描述: \(.description // "无")\n类型: \(.type // "optimization")\n预期提升: \(.expectedImprovement // "N/A")\n尝试次数: \(.attemptCount // 0)\n文件: \(.files // [] | join(", "))"' 2>/dev/null
        else
            echo "(无 pending 任务)"
        fi
        echo ""

        # 注入最近的决策记录，让 AI 避免重复失败方向
        if [ -f "$DECISIONS_FILE" ] && [ -s "$DECISIONS_FILE" ]; then
            echo "## 最近决策记录"
            echo "**不要重复以下已失败的方向。如果新方案与已失败方案本质相同，跳过此任务。**"
            echo '```jsonl'
            tail -10 "$DECISIONS_FILE" 2>/dev/null
            echo '```'
            echo ""
        fi
    fi

    # 5. Review 阶段也注入决策摘要
    if [ "$phase" = "review" ]; then
        echo "## 当前任务状态摘要"
        if [ -f "$TASK_FILE" ]; then
            jq -r '[.userStories[] | {id, title, status, actualImprovement, attemptCount}] | sort_by(.id)' "$TASK_FILE" 2>/dev/null || echo "(无法解析 prd.json)"
        fi
        echo ""


        if [ -f "$DECISIONS_FILE" ] && [ -s "$DECISIONS_FILE" ]; then
            echo "## 所有决策摘要"
            tail -20 "$DECISIONS_FILE" 2>/dev/null
            echo ""
        fi
    fi
}

# =============================================================================
# PRD / 任务查询
# =============================================================================

count_tasks_by_status() {
    local status="$1"
    jq "[.userStories[] | select(.status == \"$status\")] | length" "$TASK_FILE" 2>/dev/null || echo "0"
}

count_pending_tasks()    { count_tasks_by_status "pending"; }
count_passed_tasks()     { count_tasks_by_status "passed"; }
count_infeasible_tasks() { count_tasks_by_status "infeasible"; }

get_next_task() {
    jq '.userStories | map(select(.status == "pending")) | sort_by(.priority) | .[0]' "$TASK_FILE" 2>/dev/null
}

mark_infeasible_tasks() {
    local marked
    marked=$(jq "[.userStories[] | select(.status == \"pending\" and .attemptCount >= $MAX_TASK_ATTEMPTS)] | length" "$TASK_FILE" 2>/dev/null || echo "0")

    if [ "$marked" -gt 0 ]; then
        log_warn "将 $marked 个任务标记为 infeasible (attemptCount >= $MAX_TASK_ATTEMPTS)"
        local tmp
        tmp=$(mktemp)
        jq "(.userStories[] | select(.status == \"pending\" and .attemptCount >= $MAX_TASK_ATTEMPTS) | .status) = \"infeasible\"" \
            "$TASK_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$TASK_FILE"
    fi
}


# =============================================================================
# 收敛判断 (脚本级客观条件，不依赖 AI 自觉)
# =============================================================================

# 安全网检查：无论 pending 状态如何，满足以下条件立即终止以避免资源浪费
check_safety_net() {
    local consecutive_fails
    consecutive_fails=$(read_state consecutive_ai_failures)

    # progress.txt 过大
    if [ -f "$PROGRESS_FILE" ]; then
        local size_kb
        size_kb=$(du -k "$PROGRESS_FILE" 2>/dev/null | cut -f1)
        if [ "${size_kb:-0}" -gt "$PROGRESS_MAX_KB" ]; then
            log_warn "收敛: progress.txt 超过 ${PROGRESS_MAX_KB}KB，强制终止以保护上下文窗口"
            return 0
        fi
    fi

    # AI 连续失败
    if [ "${consecutive_fails:-0}" -ge "$CONVERGENCE_AI_FAILURES" ]; then
        log_error "收敛: AI 工具连续失败 $consecutive_fails 次"
        return 0
    fi

    return 1
}

# =============================================================================
# 迭代结果验证 & 收敛计数器更新
# =============================================================================

validate_prd() {
    if [ ! -f "$TASK_FILE" ]; then
        return 1
    fi
    if ! jq empty "$TASK_FILE" 2>/dev/null; then
        log_error "prd.json 无效 JSON"
        return 1
    fi
    if ! jq -e '.userStories' "$TASK_FILE" > /dev/null 2>&1; then
        log_error "prd.json 缺少 userStories 字段"
        return 1
    fi
    return 0
}

auto_advance_stale_task() {
    # 如果 AI 执行后任务状态未被更新，自动推进
    local task_id="$1"
    local status
    status=$(jq -r ".userStories[] | select(.id == \"$task_id\") | .status // \"unknown\"" "$TASK_FILE" 2>/dev/null)

    if [ "$status" = "pending" ] || [ "$status" = "in_progress" ]; then
        local attempts
        attempts=$(jq -r ".userStories[] | select(.id == \"$task_id\") | .attemptCount // 0" "$TASK_FILE" 2>/dev/null)
        local new_attempts=$((attempts + 1))

        log_warn "任务 $task_id 状态未更新 (当前: $status)，自动递增 attemptCount: $attempts → $new_attempts"

        local tmp
        tmp=$(mktemp)
        jq "(.userStories[] | select(.id == \"$task_id\") | .attemptCount) = $new_attempts" \
            "$TASK_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$TASK_FILE"

        if [ "$new_attempts" -ge "$MAX_TASK_ATTEMPTS" ]; then
            tmp=$(mktemp)
            jq "(.userStories[] | select(.id == \"$task_id\") | .status) = \"infeasible\"" \
                "$TASK_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$TASK_FILE"
            log_warn "任务 $task_id 自动标记为 infeasible"
        fi
    fi
}

validate_decisions() {
    # 验证 decisions.jsonl 每行都是独立可解析的 JSON
    if [ ! -f "$DECISIONS_FILE" ] || [ ! -s "$DECISIONS_FILE" ]; then
        return 0  # 空文件不需要验证
    fi

    local bad_lines=0
    local line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        if [ -n "$line" ]; then
            # 每行必须能独立被 python json.loads 解析
            if ! python3 -c "import json; json.loads('$line')" 2>/dev/null; then
                # 尝试用文件方式解析（避免 shell 转义问题）
                if ! python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    lines = f.readlines()
    try:
        json.loads(lines[$((line_num - 1))].strip())
    except json.JSONDecodeError:
        sys.exit(1)
" "$DECISIONS_FILE" 2>/dev/null; then
                    bad_lines=$((bad_lines + 1))
                    log_warn "decisions.jsonl 第 $line_num 行不是独立有效的 JSON"
                fi
            fi
        fi
    done < "$DECISIONS_FILE"

    if [ "$bad_lines" -gt 0 ]; then
        log_error "decisions.jsonl 有 $bad_lines 行格式异常（可能合并了多条记录）"
        # 尝试自动修复：将合并的多条记录拆开
        python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    content = f.read()
# 尝试修复：在 }{ 之间插入换行
fixed = content.replace('}{', '}\n{')
with open(sys.argv[1], 'w') as f:
    f.write(fixed)
print('Fixed: split merged JSON lines')
" "$DECISIONS_FILE" 2>/dev/null && log_info "decisions.jsonl 已自动修复（拆分合并行）"
    fi

    return 0
}

detect_ai_state_tampering() {
    # 检测 AI 是否非法修改了 state.json
    # 在 do_execute 和 do_review 开始前保存 state.json 的 md5，结束后对比
    local saved_md5="$1"
    if [ -z "$saved_md5" ]; then
        return 0
    fi
    local current_md5
    current_md5=$(md5sum "$STATE_FILE" 2>/dev/null | cut -d' ' -f1)
    if [ "$saved_md5" != "$current_md5" ]; then
        log_warn "state.json 被 AI 修改（md5 变化: $saved_md5 → $current_md5），将恢复脚本管理的字段"
        # 恢复关键字段：phase、iteration、consecutive_ai_failures、review_count
        # 只保留 AI 可能合法需要的 current_task 字段
        local saved_phase saved_iter saved_consec saved_review
        saved_phase=$(jq -r '.phase' "$STATE_FILE" 2>/dev/null)
        saved_iter=$(jq -r '.iteration' "$STATE_FILE" 2>/dev/null)
        saved_consec=$(jq -r '.consecutive_ai_failures' "$STATE_FILE" 2>/dev/null)
        saved_review=$(jq -r '.review_count' "$STATE_FILE" 2>/dev/null)

        # 注意：这里只记录警告，不做强制恢复，因为脚本会在下一轮重新写入正确的值
        log_warn "state.json 当前值: phase=$saved_phase, iter=$saved_iter, consec=$saved_consec, review=$saved_review"
        log_warn "脚本将在下一轮迭代时重新写入正确的阶段和计数值"
    fi
}

# =============================================================================
# 阶段处理器
# =============================================================================

do_bootstrap() {
    echo ""
    log_info "╔══════════════════════════════════════════════════════════════╗"
    log_info "║  Phase: Bootstrap — 性能分析与 PRD 生成                      ║"
    log_info "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    local prompt
    prompt=$(build_full_prompt "bootstrap")

    run_ai "$prompt" || {
        log_error "Bootstrap 阶段 AI 调用失败"
        return 1
    }

    # 验证 prd.json
    if [ ! -f "$TASK_FILE" ]; then
        log_error "Bootstrap 未生成 prd.json"
        return 1
    fi

    if ! validate_prd; then
        log_error "Bootstrap 生成的 prd.json 无效"
        return 1
    fi

    # 验证 decisions.jsonl 格式（bootstrap 可能也写入）
    validate_decisions

    # 处理 AI 选择的任务名
    if [ -f "$RUNTIME_DIR/.task_name" ]; then
        local ai_name
        ai_name=$(tr -d '\n\r' < "$RUNTIME_DIR/.task_name" | sed 's/[^a-z0-9_-]//g')
        if [ -n "$ai_name" ] && [ "$ai_name" != "$TASK_NAME" ]; then
            local new_dir="$RUNTIME_BASE/$ai_name"
            if [ -d "$new_dir" ]; then
                log_warn "任务 $ai_name 已存在，保留当前名 $TASK_NAME"
            else
                mv "$RUNTIME_DIR" "$new_dir"
                TASK_NAME="$ai_name"
                update_runtime_paths
                # 更新 state.json 和 progress.txt 中的路径引用
                log_info "任务名已更新: $TASK_NAME"
            fi
        fi
    fi

    write_state phase '"execute"'
    log_info "Bootstrap 完成 → 进入执行阶段"

    local task_count
    task_count=$(jq '.userStories | length' "$TASK_FILE")
    log_info "生成了 $task_count 个优化任务"
}

do_execute() {
    local iter="$1"

    echo ""
    log_info "==============================================================="
    log_info "  Phase: Execute — 迭代 $iter / $MAX_ITERATIONS"
    log_info "==============================================================="

    write_state iteration "$iter"

    # 保存 state.json md5，用于检测 AI 是否非法修改
    local state_md5_before
    state_md5_before=$(md5sum "$STATE_FILE" 2>/dev/null | cut -d' ' -f1)

    # 标记过度重试的任务
    mark_infeasible_tasks

    # 获取待处理任务
    local pending
    pending=$(count_pending_tasks)
    if [ "$pending" -eq 0 ]; then
        log_info "没有 pending 任务，跳过执行阶段"
        return 2  # 信号: 需要 review
    fi

    local task_info task_id task_title
    task_info=$(get_next_task)
    task_id=$(echo "$task_info" | jq -r '.id // "unknown"')
    task_title=$(echo "$task_info" | jq -r '.title // "unknown"')
    write_state current_task "\"$task_id\""

    log_info "执行任务: $task_id — $task_title"

    # 构建提示词并运行 AI
    local prompt ai_exit
    prompt=$(build_full_prompt "execute")
    ai_exit=0
    run_ai "$prompt" || ai_exit=$?

    # 处理 AI 退出码
    if [ "$ai_exit" -ne 0 ]; then
        log_warn "AI 工具返回非零退出码: $ai_exit"
        increment_state consecutive_ai_failures
    else
        write_state consecutive_ai_failures 0
    fi

    # 检测 AI 是否修改了 state.json
    detect_ai_state_tampering "$state_md5_before"

    # 验证 prd.json 完整性
    if ! validate_prd; then
        log_error "AI 执行后 prd.json 损坏"
        # 尝试继续；下次迭代的 AI 或许能修复
    fi

    # 验证 decisions.jsonl 格式（每行独立可解析）
    validate_decisions

    # 检查任务状态是否被正确更新，未更新则自动推进
    auto_advance_stale_task "$task_id"

    write_state current_task null
    return 0
}

do_review() {
    echo ""
    log_info "╔══════════════════════════════════════════════════════════════╗"
    log_info "║  Phase: Review — 评估整体进展                                ║"
    log_info "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    # 保存 state.json md5，用于检测 AI 是否非法修改
    local state_md5_before
    state_md5_before=$(md5sum "$STATE_FILE" 2>/dev/null | cut -d' ' -f1)

    increment_state review_count

    local pending_before
    pending_before=$(count_pending_tasks)

    local prompt
    prompt=$(build_full_prompt "review")

    run_ai "$prompt" || {
        log_error "Review 阶段 AI 调用失败"
        return 1
    }

    # 检测 AI 是否修改了 state.json
    detect_ai_state_tampering "$state_md5_before"

    # 验证 decisions.jsonl 格式
    validate_decisions

    # 检查 COMPLETE 标记
    if grep -q "<promise>COMPLETE</promise>" "$PROGRESS_FILE" 2>/dev/null; then
        log_info "AI 已标记 COMPLETE — 优化循环完成"
        write_state phase '"done"'
        return 0
    fi

    # 检查是否生成了新任务
    local pending_after
    pending_after=$(count_pending_tasks)

    if [ "$pending_after" -gt 0 ]; then
        local new_count=$((pending_after - pending_before))
        log_info "Review 生成了 $new_count 个新任务，继续执行阶段"
        write_state phase '"execute"'
        return 0
    fi

    # 没有新任务也没有 COMPLETE → 自动完成
    log_info "Review 后无新 pending 任务且未标记 COMPLETE，自动结束"
    if ! grep -q "<promise>COMPLETE</promise>" "$PROGRESS_FILE" 2>/dev/null; then
        cat >> "$PROGRESS_FILE" << EOF

<promise>COMPLETE</promise>

## 优化总结 (自动生成)
- Review 后无新优化任务生成
- 所有可行方向已尝试
- 结束时间: $(timestamp)
EOF
    fi
    write_state phase '"done"'
    return 0
}

# =============================================================================
# 运行时初始化
# =============================================================================

generate_temp_task_name() {
    echo "new_task_$(date +%s)"
}

update_runtime_paths() {
    RUNTIME_DIR="$RUNTIME_BASE/$TASK_NAME"
    TASK_FILE="$RUNTIME_DIR/prd.json"
    PROGRESS_FILE="$RUNTIME_DIR/progress.txt"
    DECISIONS_FILE="$RUNTIME_DIR/decisions.jsonl"
    STATE_FILE="$RUNTIME_DIR/state.json"
    ANALYSIS_FILE="$RUNTIME_DIR/analysis.json"
    LOG_FILE="$RUNTIME_DIR/log.txt"
}

init_runtime() {
    mkdir -p "$RUNTIME_DIR"

    # 初始化日志
    if [ ! -f "$LOG_FILE" ]; then
        echo "# Ralph 执行日志 — $(timestamp)" > "$LOG_FILE"
        echo "" >> "$LOG_FILE"
    fi

    # 初始化进度文件
    if [ ! -f "$PROGRESS_FILE" ]; then
        cat > "$PROGRESS_FILE" << EOF
# Ralph 进度日志

## 会话信息
- 开始时间: $(timestamp)
- 工作目录: $SCRIPT_DIR
- 任务名: $TASK_NAME
- 用户目标: ${INITIAL_PROMPT:-无}

---

## 硬件能力汇总
<!-- ⚠️ AI 必须在此处填充内容，不要删除此标记，不要覆盖整个文件。保留标题 ## 硬件能力汇总，将本注释替换为实际内容。 -->

---

## 经验能力汇总
<!-- ⚠️ AI 在迭代中逐步填充此章节。保留标题 ## 经验能力汇总，将本注释替换为实际内容。 -->

---

EOF
    fi

    # 初始化状态文件
    init_state
}

# =============================================================================
# Git 安全
# =============================================================================

ensure_gitignore() {
    local gitignore="$SCRIPT_DIR/.gitignore"
    local entries=("runtime/" "ralph-loop.sh" "ralph-prompts/")
    local changed=0

    for entry in "${entries[@]}"; do
        if ! grep -qxF "$entry" "$gitignore" 2>/dev/null; then
            echo "$entry" >> "$gitignore"
            changed=1
        fi
    done

    [ "$changed" -eq 1 ] && log_info ".gitignore 已更新"

    # 取消跟踪已被 git 管理的 runtime 文件
    if git ls-files --error-unmatch "$RUNTIME_BASE" &>/dev/null 2>&1; then
        log_info "从 git 跟踪中移除 runtime/"
        git rm --cached -r "$RUNTIME_BASE" 2>/dev/null || true
    fi
}

# =============================================================================
# 状态显示
# =============================================================================

show_status() {
    echo ""
    log_info "=== Ralph Loop 状态 ==="
    echo ""
    log_info "工作目录:    $SCRIPT_DIR"
    log_info "运行时目录:  $RUNTIME_DIR"
    log_info "AI 工具:     $AI_TOOL"
    log_info "提示词目录:  $PROMPTS_DIR"
    log_info "阶段:        $(read_state phase 2>/dev/null || echo '?')"
    log_info "迭代:        $(read_state iteration 2>/dev/null || echo 0) / $MAX_ITERATIONS"
    log_info "连续AI失败:  $(read_state consecutive_ai_failures 2>/dev/null || echo 0)"
    log_info "Review 次数: $(read_state review_count 2>/dev/null || echo 0) / $MAX_REVIEWS"
    echo ""

    if [ -f "$TASK_FILE" ] && validate_prd 2>/dev/null; then
        local total passed pending attempted infeasible inprog
        total=$(jq '.userStories | length' "$TASK_FILE" 2>/dev/null || echo "0")
        passed=$(count_passed_tasks)
        pending=$(count_pending_tasks)
        attempted=$(count_tasks_by_status "attempted")
        infeasible=$(count_infeasible_tasks)
        inprog=$(count_tasks_by_status "in_progress")

        log_info "任务分布:  总计=$total | passed=$passed | pending=$pending | attempted=$attempted | infeasible=$infeasible | in_progress=$inprog"

        if [ "$total" -gt 0 ]; then
            local resolved=$((passed + attempted + infeasible))
            local percent=$((resolved * 100 / total))
            local filled=$((percent / 5))
            local empty=$((20 - filled))
            local bar
            bar=$(printf '█%.0s' $(seq 1 $filled))$(printf '░%.0s' $(seq 1 $empty))
            log_info "进度:       [$bar] ${percent}%"
        fi
        echo ""

        if [ "$pending" -gt 0 ]; then
            log_info "下一个任务:"
            get_next_task | jq -r '"  ID: \(.id)\n  标题: \(.title)\n  优先级: \(.priority)\n  类型: \(.type // "optimization")\n  尝试次数: \(.attemptCount // 0)"' 2>/dev/null
            echo ""
        fi

        if jq -e '.baselinePerf.benchmarks' "$TASK_FILE" > /dev/null 2>&1; then
            local benchmarks_count
            benchmarks_count=$(jq '[.baselinePerf.benchmarks // [] | .[]] | length' "$TASK_FILE" 2>/dev/null || echo "0")
            if [ "$benchmarks_count" -gt 0 ]; then
                log_info "关注用例 ($benchmarks_count 个):"
                jq -r '[.baselinePerf.benchmarks // [] | .[] | select(.ratio != null and (.ratio | tonumber) > 1.05)] | sort_by(-(.ratio | tonumber)) | .[] | "  \(.benchmark | if length > 60 then .[0:60] + "…" else . end)  ratio=\(.ratio)  \(.before) → \(.after)"' "$TASK_FILE" 2>/dev/null
            fi
        fi
        echo ""

    else
        log_info "尚无有效 prd.json"
        echo ""
    fi

    if [ -f "$PROGRESS_FILE" ]; then
        log_info "最近进度:"
        # 从 decisions.jsonl 提取结构化数据，展示每条记录的关键信息
        if [ -f "$DECISIONS_FILE" ] && [ -s "$DECISIONS_FILE" ]; then
            cat "$DECISIONS_FILE" 2>/dev/null | jq -r '"[\(.iter)] \(.task_id) \(.result) \(.perf_change_pct | if . > 0 then "+" + (. | tostring) + "%" else (. | tostring) + "%" end) — \(.action | if length > 50 then .[0:50] + "…" else . end)"' 2>/dev/null || echo "  (decisions.jsonl 解析失败)"
        else
            echo "  (无决策记录)"
        fi
        echo ""

        if grep -q "<promise>COMPLETE</promise>" "$PROGRESS_FILE" 2>/dev/null; then
            log_info "✓ 已标记 COMPLETE"
            echo ""
        fi
    fi
}

list_all_tasks() {
    echo ""
    log_info "=== 所有 Ralph 任务 ==="
    echo ""

    if [ ! -d "$RUNTIME_BASE" ] || [ -z "$(ls -A "$RUNTIME_BASE" 2>/dev/null)" ]; then
        log_info "暂无任务。使用 -p 参数启动新任务。"
        echo ""
        return
    fi

    printf "%-35s %-6s %-8s %-8s %s\n" "任务名" "总" "已过" "阶段" "项目"
    printf "%-35s %-6s %-8s %-8s %s\n" "-----------------------------------" "------" "--------" "--------" "------------------------------"

    for d in "$RUNTIME_BASE"/*/; do
        [ -d "$d" ] || continue
        local name total passed phase project
        name=$(basename "$d")
        if [ -f "$d/prd.json" ]; then
            total=$(jq '.userStories | length' "$d/prd.json" 2>/dev/null || echo "-")
            passed=$(jq '[.userStories[] | select(.status == "passed")] | length' "$d/prd.json" 2>/dev/null || echo "-")
            phase=$(jq -r '.phase // "?"' "$d/state.json" 2>/dev/null || echo "-")
            project=$(jq -r '.project // "N/A"' "$d/prd.json" 2>/dev/null)
            printf "%-35s %-6s %-8s %-8s %s\n" "$name" "$total" "$passed" "$phase" "$project"
        else
            printf "%-35s %-6s %-8s %-8s %s\n" "$name" "-" "-" "-" "无 prd.json"
        fi
    done
    echo ""
}

# =============================================================================
# 清理
# =============================================================================

clean_task() {
    if [ ! -d "$RUNTIME_DIR" ]; then
        log_error "任务 '$TASK_NAME' 不存在"
        list_all_tasks
        exit 1
    fi

    log_info "=== 清理任务: $TASK_NAME ==="
    echo ""
    log_info "待删除: $RUNTIME_DIR/"
    echo ""
    read -r -p "确认清理? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -rf "$RUNTIME_DIR"
        log_info "✓ 已清理: $TASK_NAME"
    else
        log_info "已取消"
    fi
}

# =============================================================================
# 帮助
# =============================================================================

show_help() {
    cat << EOF
用法: $0 [命令] [选项]

命令:
  status [-n <任务名>]      列出所有任务或显示指定任务状态
  clean  -n <任务名>        清理指定任务的运行时文件

选项:
  -p, --prompt TEXT         优化目标 (启动新任务时使用)
  -n, --task-name NAME      任务名 (继续现有任务或指定新任务名)
  -i, --max-iter N          最大迭代次数 (默认: $MAX_ITERATIONS)
  -t, --tool TOOL           AI 工具: claude 或 opencode
  -h, --help                显示帮助

示例:
  $0 status                              # 列出所有任务
  $0 status -n opt_searchsort            # 查看任务状态
  $0 clean -n opt_searchsort             # 清理任务
  $0 -i 10 -p "优化 searchsort 算子"     # 启动新优化任务
  $0 -n opt_searchsort -i 5              # 继续已有任务
  $0 -n opt_searchsort -t claude         # 使用 claude 继续任务

环境变量:
  RALPH_TOOL                 默认 AI 工具 (claude/opencode)
  RALPH_MAX_ITERATIONS       最大迭代次数
  RALPH_MAX_TASK_ATTEMPTS    单个任务最大尝试次数 (默认: 3)
  RALPH_MAX_REVIEWS          review 阶段最大次数 (默认: 3)
  RALPH_PROMPTS_DIR          提示词目录路径
EOF
}

# =============================================================================
# 参数解析 & 主入口
# =============================================================================

parse_args() {
    # 检查是否是命令模式 (status / clean)
    case "${1:-}" in
        status|--status)
            shift
            # 解析 -n <任务名>
            local status_name=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    -n|--task|--task-name) status_name="$2"; shift 2 ;;
                    --task=*|--task-name=*) status_name="${1#*=}"; shift ;;
                    *) status_name="$1"; shift ;;
                esac
            done
            if [ -z "$status_name" ]; then
                TASK_NAME=""
                update_runtime_paths  # 设默认路径（不会用到但避免未绑定变量）
                list_all_tasks
                exit 0
            fi
            TASK_NAME="$status_name"
            update_runtime_paths
            if [ ! -d "$RUNTIME_DIR" ]; then
                log_error "任务 '$TASK_NAME' 不存在"
                list_all_tasks
                exit 1
            fi
            show_status
            exit 0
            ;;
        clean|--clean)
            shift
            local clean_name=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    -n|--task|--task-name) clean_name="$2"; shift 2 ;;
                    --task=*|--task-name=*) clean_name="${1#*=}"; shift ;;
                    *) clean_name="$1"; shift ;;
                esac
            done
            if [ -z "$clean_name" ]; then
                log_error "clean 需要指定任务名。用法: $0 clean -n <任务名>"
                list_all_tasks
                exit 1
            fi
            TASK_NAME="$clean_name"
            update_runtime_paths
            clean_task
            exit 0
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
    esac

    # 解析选项参数
    while [ $# -gt 0 ]; do
        case "$1" in
            --max-iter|--max-iterations|-i)
                MAX_ITERATIONS="$2"; shift 2 ;;
            --max-iter=*|--max-iterations=*)
                MAX_ITERATIONS="${1#*=}"; shift ;;
            --prompt|-p)
                INITIAL_PROMPT="$2"; shift 2 ;;
            --prompt=*)
                INITIAL_PROMPT="${1#*=}"; shift ;;
            --task-name|--task|-n)
                TASK_NAME="$2"; shift 2 ;;
            --task-name=*|--task=*)
                TASK_NAME="${1#*=}"; shift ;;
            --tool|--ai-tool|-t)
                AI_TOOL="$2"; shift 2 ;;
            --tool=*|--ai-tool=*)
                AI_TOOL="${1#*=}"; shift ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                if [[ "$1" =~ ^[0-9]+$ ]]; then
                    MAX_ITERATIONS="$1"; shift
                else
                    log_error "未知选项: $1 (使用 --help 查看帮助)"
                    exit 1
                fi
                ;;
        esac
    done
}

main() {
    parse_args "$@"

    # 依赖检查
    if ! command -v jq &> /dev/null; then
        log_error "需要 jq。安装: apt install jq"
        exit 1
    fi

    # AI 工具: 参数 > 环境变量 > 自动检测
    if [ -z "${AI_TOOL:-}" ]; then
        AI_TOOL="${RALPH_TOOL:-}"
    fi
    if [ -z "${AI_TOOL:-}" ]; then
        AI_TOOL=$(detect_ai_tool)
    fi
    case "${AI_TOOL}" in
        opencode|claude) ;;
        "")
            log_error "未找到 AI 工具 (claude/opencode)"
            log_error "安装: npm install -g @anthropic-ai/claude-code"
            exit 1
            ;;
        *)
            log_error "不支持的 AI 工具: $AI_TOOL (支持: claude, opencode)"
            exit 1
            ;;
    esac

    # 任务名推导
    if [ -z "${TASK_NAME:-}" ] && [ -n "${INITIAL_PROMPT:-}" ]; then
        TASK_NAME=$(generate_temp_task_name)
        log_info "临时任务名: $TASK_NAME (AI 将在 bootstrap 阶段确定最终名称)"
    elif [ -z "${TASK_NAME:-}" ]; then
        TASK_NAME="default"
    fi

    update_runtime_paths
    init_runtime
    ensure_gitignore

    # 头部信息
    echo ""
    log_info "╔══════════════════════════════════════════════════════════════╗"
    log_info "║       Ralph Loop v2.0 — NumPy 自适应性能优化                  ║"
    log_info "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    log_info "任务:        $TASK_NAME"
    log_info "运行时目录:  $RUNTIME_DIR"
    log_info "AI 工具:     $AI_TOOL"
    log_info "最大迭代:    $MAX_ITERATIONS"
    log_info "最大 Review:  $MAX_REVIEWS 次"
    log_info "提示词目录:  $PROMPTS_DIR"
    log_info "最大尝试:    每任务 $MAX_TASK_ATTEMPTS 次"
    echo ""

    # Bootstrap
    if [ ! -f "$TASK_FILE" ]; then
        do_bootstrap || {
            log_error "Bootstrap 失败，退出"
            exit 1
        }
    else
        log_info "发现已有 prd.json，跳过 bootstrap"
    fi

    show_status

    # =========================================================================
    # 主循环
    # =========================================================================

    local final_exit=0
    local iter
    iter=$(read_state iteration 2>/dev/null || echo 0)
    iter=$((iter + 1))

    while [ "$iter" -le "$MAX_ITERATIONS" ]; do
        # 安全网检查 (AI 连续失败、progress.txt 过大等硬性条件)
        if check_safety_net; then
            final_exit=0
            break
        fi

        # 检查是否需要 review
        local pending
        pending=$(count_pending_tasks)

        if [ "$pending" -eq 0 ]; then
            # 所有任务已尝试 → 检查是否已达优化极限
            if check_safety_net; then
                final_exit=0
                break
            fi

            # 检查 review 次数上限
            local review_count
            review_count=$(read_state review_count 2>/dev/null || echo 0)
            if [ "${review_count:-0}" -ge "$MAX_REVIEWS" ]; then
                log_info "已达到 review 上限 ($MAX_REVIEWS 次)，自动结束"
                if ! grep -q "<promise>COMPLETE</promise>" "$PROGRESS_FILE" 2>/dev/null; then
                    cat >> "$PROGRESS_FILE" << EOF

<promise>COMPLETE</promise>

## 优化总结 (达到 review 上限)
- Review 次数: $review_count (上限: $MAX_REVIEWS)
- 结束时间: $(timestamp)
- 结束原因: 达到 review 上限
EOF
                fi
                write_state phase '"done"'
                final_exit=0
                break
            fi

            # 进入 review 阶段，评估是否生成新任务
            do_review || true

            if [ "$(read_state phase)" = "done" ]; then
                final_exit=0
                break
            fi

            # review 后重新检查
            pending=$(count_pending_tasks)
            if [ "$pending" -eq 0 ]; then
                log_info "Review 后无新任务，循环结束"
                break
            fi

            # review 产生了新任务，交给下一轮迭代执行
        else
            # 执行一个任务
            do_execute "$iter" || true
        fi

        show_status
        iter=$((iter + 1))
    done

    # =========================================================================
    # 结束
    # =========================================================================

    if [ "$iter" -gt "$MAX_ITERATIONS" ]; then
        log_info "达到最大迭代次数 ($MAX_ITERATIONS)"
        write_state phase '"max_iterations"'
    fi

    echo ""
    log_info "╔══════════════════════════════════════════════════════════════╗"
    log_info "║       Ralph Loop 结束                                         ║"
    log_info "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    log_info "执行了 $((iter - 1)) 次迭代"
    log_info "进度保存: $PROGRESS_FILE"
    log_info "任务状态: $TASK_FILE"
    log_info "决策日志: $DECISIONS_FILE"
    show_status

    exit $final_exit
}

# =============================================================================
# 入口
# =============================================================================

main "$@"