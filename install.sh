#!/usr/bin/env bash
# Ralph Loop for NumPy — 一键安装脚本
# 用法: curl -fsSL https://raw.githubusercontent.com/pdlzs/ralph-loop-for-numpy/main/install.sh | bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }

# ---------- 平台检测 ----------
detect_os() {
    case "$(uname -s)" in
        Linux)  echo "linux" ;;
        Darwin) echo "macos" ;;
        *)      echo "unknown" ;;
    esac
}

OS=$(detect_os)

# ---------- 检查命令是否存在 ----------
has() { command -v "$1" &>/dev/null; }

# ---------- 安装 jq ----------
install_jq() {
    if has jq; then
        log_info "jq 已安装: $(jq --version 2>&1)"
        return
    fi

    log_step "安装 jq..."
    case "$OS" in
        linux)
            if has apt-get; then
                sudo apt-get update -qq && sudo apt-get install -y -qq jq
            elif has dnf; then
                sudo dnf install -y -q jq
            elif has yum; then
                sudo yum install -y -q jq
            elif has pacman; then
                sudo pacman -S --noconfirm jq
            else
                log_error "未检测到支持的包管理器，请手动安装 jq"
                exit 1
            fi
            ;;
        macos)
            if has brew; then
                brew install jq
            else
                log_error "macOS 需要 Homebrew，请先安装: https://brew.sh"
                exit 1
            fi
            ;;
    esac
    log_info "jq 安装完成"
}

# ---------- 检查 Python 3 ----------
check_python3() {
    if has python3; then
        log_info "python3 已安装: $(python3 --version 2>&1)"
    else
        log_error "未找到 python3，请先安装 Python 3"
        case "$OS" in
            linux)
                log_error "  Ubuntu/Debian: sudo apt install python3"
                log_error "  Fedora/RHEL:   sudo dnf install python3"
                ;;
            macos)
                log_error "  brew install python3"
                ;;
        esac
        exit 1
    fi
}

# ---------- 安装 nvm + Node.js ----------
install_node() {
    local min_ver=18

    # 检查当前 node 版本是否达标
    if has node && has npm; then
        local node_major
        node_major=$(node --version | sed 's/v//' | cut -d. -f1)
        if [ "$node_major" -ge "$min_ver" ]; then
            log_info "Node.js 已安装: $(node --version)"
            return
        fi
        log_warn "当前 Node.js $(node --version) 版本过低（需要 >= $min_ver），将使用 nvm 安装新版本"
    fi

    local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
    local nvm_script="$nvm_dir/nvm.sh"

    # 加载 nvm
    if [ -s "$nvm_script" ]; then
        . "$nvm_script"
        # 检查 nvm 管理的 node 版本是否达标
        if has node; then
            local nvm_major
            nvm_major=$(node --version | sed 's/v//' | cut -d. -f1)
            if [ "$nvm_major" -ge "$min_ver" ]; then
                log_info "nvm 管理的 Node.js 已达标: $(node --version)"
                return
            fi
        fi
    else
        log_step "安装 nvm..."
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
        . "$nvm_script"
    fi

    log_step "通过 nvm 安装 Node.js LTS..."
    nvm install --lts
    nvm use --lts
    nvm alias default lts/*
    log_info "Node.js 安装完成: $(node --version)"
    log_info "npm 版本: $(npm --version)"
}

# ---------- 确保使用 nvm 的 node ----------
use_nvm_node() {
    local nvm_script="${NVM_DIR:-$HOME/.nvm}/nvm.sh"
    if [ -s "$nvm_script" ]; then
        . "$nvm_script"
        nvm use default &>/dev/null || nvm use --lts &>/dev/null || true
    fi
}

# ---------- 安装 Claude Code ----------
install_claude() {
    use_nvm_node

    if has claude; then
        log_info "Claude Code 已安装"
        return
    fi

    log_step "安装 Claude Code..."
    npm install -g @anthropic-ai/claude-code
    log_info "Claude Code 安装完成"
}

# ---------- 部署项目文件到当前目录 ----------
deploy_project() {
    local repo_url="https://github.com/pdlzs/ralph-loop-for-numpy.git"
    local dest_dir="${1:-.}"

    # 解析为绝对路径
    dest_dir="$(cd "$dest_dir" 2>/dev/null && pwd || echo "$dest_dir")"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" EXIT

    log_step "下载项目文件到 $dest_dir ..."
    git clone --depth 1 "$repo_url" "$tmp_dir"

    # 复制项目文件到目标目录（排除 .git 和 install.sh 自身）
    for item in ralph-loop.sh ralph-prompts .claude; do
        if [ -e "$tmp_dir/$item" ]; then
            cp -r "$tmp_dir/$item" "$dest_dir/"
        fi
    done

    chmod +x "$dest_dir/ralph-loop.sh"
    log_info "ralph-loop.sh 已部署到 $dest_dir/"
}

# ---------- 验证 ----------
verify() {
    use_nvm_node
    echo ""
    log_info "======== 安装验证 ========"
    has jq      && echo -e "  jq:       ${GREEN}$(jq --version 2>&1)${NC}"        || echo -e "  jq:       ${RED}未安装${NC}"
    has python3 && echo -e "  python3:  ${GREEN}$(python3 --version 2>&1)${NC}"   || echo -e "  python3:  ${RED}未安装${NC}"
    has node    && echo -e "  node:     ${GREEN}$(node --version 2>&1)${NC}"      || echo -e "  node:     ${RED}未安装${NC}"
    has npm     && echo -e "  npm:      ${GREEN}$(npm --version 2>&1)${NC}"       || echo -e "  npm:      ${RED}未安装${NC}"
    has claude  && echo -e "  claude:   ${GREEN}已安装${NC}"                       || echo -e "  claude:   ${YELLOW}未安装${NC}"
    echo ""
}

# ---------- 帮助 ----------
show_help() {
    cat << EOF
Ralph Loop for NumPy — 一键安装脚本

用法:
  curl -fsSL https://.../install.sh | bash            # 默认: 安装依赖 + 部署项目文件到当前目录
  curl -fsSL https://.../install.sh | bash -s -- [选项]

选项:
  --deps-only              仅安装依赖，不部署项目文件
  --dir PATH               项目部署目录 (默认: 当前目录)
  --help                   显示此帮助

示例:
  curl -fsSL .../install.sh | bash                         # 全部安装到当前目录
  curl -fsSL .../install.sh | bash -s -- --deps-only       # 仅依赖
  curl -fsSL .../install.sh | bash -s -- --dir /opt/ralph  # 部署到指定目录
EOF
}

# ---------- 主流程 ----------
main() {
    local deps_only=false
    local deploy_dir="."

    while [ $# -gt 0 ]; do
        case "$1" in
            --deps-only) deps_only=true; shift ;;
            --dir)       deploy_dir="$2"; shift 2 ;;
            --help)      show_help; exit 0 ;;
            *)           log_warn "未知参数: $1 (--help 查看帮助)"; shift ;;
        esac
    done

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     Ralph Loop for NumPy — 一键安装                         ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    log_info "平台: $OS"

    # 检查基础前提
    if ! has curl && ! has wget; then
        log_error "需要 curl 或 wget，请先安装"
        exit 1
    fi
    if ! has git; then
        log_error "需要 git，请先安装"
        case "$OS" in
            linux) log_error "  sudo apt install git" ;;
            macos) log_error "  brew install git"     ;;
        esac
        exit 1
    fi

    install_jq
    check_python3
    install_node
    use_nvm_node
    install_claude

    if [ "$deps_only" = false ]; then
        deploy_project "$deploy_dir"
    fi

    verify

    if [ "$deps_only" = false ]; then
        deploy_dir="$(cd "$deploy_dir" 2>/dev/null && pwd || echo "$deploy_dir")"
        log_info "安装完成！开始使用:"
        echo ""
        echo -e "  ${GREEN}cd $deploy_dir${NC}"
        echo -e "  ${GREEN}./ralph-loop.sh --help${NC}"
        echo ""
        echo -e "${YELLOW}⚠ 请编辑 .claude/settings.json，将 ANTHROPIC_AUTH_TOKEN 替换为你的 API Key:${NC}"
        echo -e "  ${GREEN}sed -i 's/\"sk-xxx\"/\"sk-你的真实Key\"/' $deploy_dir/.claude/settings.json${NC}"
    else
        log_info "依赖安装完成"
    fi
    echo ""
}

main "$@"
