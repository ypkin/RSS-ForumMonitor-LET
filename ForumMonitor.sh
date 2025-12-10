#!/bin/bash

# --- ForumMonitor 管理脚本 (v79: StableFix) ---
# Version: 2025.12.10.79-StableFix
# Changes:
# [x] Fix: 移除了 set -e，防止菜单交互意外退出。
# [x] Fix: 修复了 JSON 配置文件中可能出现的控制字符报错 (Parse error)。
# [x] Fix: 加固了心跳检测逻辑，防止算术错误。
# [x] Core: Python 核心逻辑保持不变 (v78)。
#
# --- (c) 2025 ---

# set -e  <-- 已禁用，防止交互时崩溃
set -u

# --- 全局变量 ---
APP_DIR="/opt/forum-monitor"
VENV_DIR="$APP_DIR/venv"
SERVICE_NAME="forum-monitor"
PYTHON_SCRIPT_NAME="core.py"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
CONFIG_FILE="$APP_DIR/data/config.json"
HEARTBEAT_FILE="$APP_DIR/data/heartbeat.txt"
STATS_FILE="$APP_DIR/data/stats.json"
RESTART_LOG_FILE="$APP_DIR/data/restart_log.txt"
SHORTCUT_PATH="/usr/local/bin/fm"
UPDATE_URL="https://raw.githubusercontent.com/ypkin/RSS-ForumMonitor-LET/refs/heads/ForumMonitor-with-gemini/ForumMonitor.sh"

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# --- 基础检查 ---

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误: 请使用 root 用户运行此脚本。${NC}"
    exit 1
fi

msg_info() { echo -e "${BLUE}[INFO] ${NC}$1"; }
msg_ok() { echo -e "${GREEN}[OK] ${NC}$1"; }
msg_warn() { echo -e "${YELLOW}[WARN] ${NC}$1"; }
msg_err() { echo -e "${RED}[ERROR] ${NC}$1"; }

check_service_exists() {
    if [ ! -f "$SYSTEMD_SERVICE_FILE" ]; then
        msg_err "服务 $SERVICE_NAME 未安装。请先运行 'install' (选项 1)。"
        exit 1
    fi
}

check_jq() {
    if ! command -v jq &> /dev/null; then
        msg_info "正在安装 jq..."
        apt-get update -qq && apt-get install -y -qq jq
    fi
}

# --- 核心：杀掉幽灵日志进程 ---
kill_zombie_loggers() {
    if pgrep -f "journalctl -u $SERVICE_NAME" > /dev/null; then
        pkill -9 -f "journalctl -u $SERVICE_NAME" > /dev/null 2>&1 || true
    fi
}

get_uptime() {
    if systemctl is-active --quiet $SERVICE_NAME; then
        local PID=$(systemctl show --property MainPID --value $SERVICE_NAME)
        if [ -n "$PID" ] && [ "$PID" -ne 0 ]; then
            ps -p "$PID" -o etime= | xargs
        else
            echo "启动中..."
        fi
    else
        echo "-"
    fi
}

# --- 核心功能模块 ---

show_dashboard() {
    kill_zombie_loggers
    check_jq
    local STATUS_TEXT="已停止 (Stopped)"
    local STATUS_COLOR="$RED"
    
    if systemctl is-active --quiet $SERVICE_NAME; then
        STATUS_TEXT="运行中 (Running)"
        STATUS_COLOR="$GREEN"
    fi

    local UPTIME=$(get_uptime)
    local PUSH_COUNT=0
    [ -f "$STATS_FILE" ] && PUSH_COUNT=$(jq -r '.push_count // 0' "$STATS_FILE" 2>/dev/null || echo "0")
    
    local RESTART_COUNT=0
    [ -f "$RESTART_LOG_FILE" ] && RESTART_COUNT=$(wc -l < "$RESTART_LOG_FILE")
    
    local CUR_PROVIDER="gemini"
    local CUR_MODEL="Unknown"
    local CUR_FREQ="300"
    
    # Push Status
    local S_PP="ON"
    local S_TG="ON"
    local C_PP="GREEN"
    local C_TG="GREEN"
    
    if [ -f "$CONFIG_FILE" ]; then
        # 使用 2>/dev/null 防止 JSON 解析错误刷屏
        CUR_PROVIDER=$(jq -r '.config.ai_provider // "gemini"' "$CONFIG_FILE" 2>/dev/null || echo "gemini")
        if [ "$CUR_PROVIDER" == "workers" ]; then
             CUR_MODEL=$(jq -r '.config.cf_model // "llama-3.1-8b"' "$CONFIG_FILE" 2>/dev/null)
        else
             CUR_MODEL=$(jq -r '.config.model // "gemini-2.0-flash-lite"' "$CONFIG_FILE" 2>/dev/null)
        fi
        CUR_FREQ=$(jq -r '.config.frequency // 300' "$CONFIG_FILE" 2>/dev/null || echo "300")
        
        local RAW_PP=$(jq -r '.config.enable_pushplus' "$CONFIG_FILE" 2>/dev/null | xargs)
        local RAW_TG=$(jq -r '.config.enable_telegram' "$CONFIG_FILE" 2>/dev/null | xargs)
        
        if [ "$RAW_PP" == "false" ]; then S_PP="OFF"; C_PP="GRAY"; fi
        if [ "$RAW_TG" == "false" ]; then S_TG="OFF"; C_TG="GRAY"; fi
    fi

    echo -e "${BLUE}================================================================${NC}"
    echo -e " ${CYAN}ForumMonitor (v79: StableFix)${NC}"
    echo -e "${BLUE}================================================================${NC}"
    printf " %-16s %b%-20s%b | %-16s %b%-10s%b\n" "运行状态:" "$STATUS_COLOR" "$STATUS_TEXT" "$NC" "已推送通知:" "$GREEN" "$PUSH_COUNT" "$NC"
    printf " %-16s %b%-20s%b | %-16s %b%-10s%b\n" "AI 引擎:" "$CYAN" "${CUR_PROVIDER^^}" "$NC" "轮询间隔:" "$CYAN" "${CUR_FREQ}s" "$NC"
    printf " %-16s %b%-20s%b | %-16s %b%-10s%b\n" "当前模型:" "$CYAN" "${CUR_MODEL:0:18}.." "$NC" "自动重启:" "$RED" "$RESTART_COUNT 次" "$NC"
    echo -e "${GRAY}----------------------------------------------------------------${NC}"
    printf " %-16s %b%-20s%b | %-16s %b%-10s%b\n" "Pushplus:" "${!C_PP}" "$S_PP" "$NC" "Telegram:" "${!C_TG}" "$S_TG" "$NC"
    echo -e "${BLUE}================================================================${NC}"
}

run_start() {
    check_service_exists
    msg_info "正在启动服务..."
    systemctl start $SERVICE_NAME
    msg_ok "服务已启动"
}

run_stop() {
    check_service_exists
    msg_info "正在停止服务..."
    systemctl stop $SERVICE_NAME
    pkill -f "$APP_DIR/$PYTHON_SCRIPT_NAME" || true
    pkill -9 -f "$APP_DIR/$PYTHON_SCRIPT_NAME" || true
    msg_ok "服务已停止"
}

run_restart() {
    check_service_exists
    msg_info "正在重启服务..."
    systemctl stop $SERVICE_NAME
    pkill -f "$APP_DIR/$PYTHON_SCRIPT_NAME" || true
    pkill -9 -f "$APP_DIR/$PYTHON_SCRIPT_NAME" || true
    systemctl start $SERVICE_NAME
    msg_ok "服务已重启"
}

run_toggle_push() {
    check_service_exists
    check_jq
    
    while true; do
        clear
        echo -e "${BLUE}================================================================${NC}"
        echo -e " ${CYAN}推送通道开关 (Toggle Push Channels)${NC}"
        echo -e "${BLUE}================================================================${NC}"

        local PP_ST=$(jq -r '.config.enable_pushplus' "$CONFIG_FILE" 2>/dev/null | xargs)
        local TG_ST=$(jq -r '.config.enable_telegram' "$CONFIG_FILE" 2>/dev/null | xargs)
        [ "$PP_ST" == "null" ] || [ -z "$PP_ST" ] && PP_ST="true"
        [ "$TG_ST" == "null" ] || [ -z "$TG_ST" ] && TG_ST="true"
        
        local PP_DISP="${GREEN}✅ ON (开启)${NC}"
        local TG_DISP="${GREEN}✅ ON (开启)${NC}"
        
        if [ "$PP_ST" == "false" ]; then PP_DISP="${GRAY}❌ OFF (已关闭)${NC}"; fi
        if [ "$TG_ST" == "false" ]; then TG_DISP="${GRAY}❌ OFF (已关闭)${NC}"; fi

        echo -e "  1. Pushplus 推送: $PP_DISP"
        echo -e "  2. Telegram 推送: $TG_DISP"
        echo -e "${GRAY}----------------------------------------------------------------${NC}"
        echo -e "  0. 返回上级菜单"
        echo -e "${BLUE}================================================================${NC}"
        
        echo -e "${YELLOW}请选择你要打开或者关闭的推送方式 (输入数字):${NC}"
        read -p "选项: " OPT
        
        case "$OPT" in
            1)
                echo -e "正在更改 Pushplus 状态..."
                if [ "$PP_ST" == "true" ]; then
                    jq '.config.enable_pushplus = false' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                    msg_warn "Pushplus -> OFF"
                else
                    jq '.config.enable_pushplus = true' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                    msg_ok "Pushplus -> ON"
                fi
                sync; run_restart
                echo -e "${GRAY}按任意键刷新界面...${NC}"; read -n 1 -s -r
                ;;
            2)
                echo -e "正在更改 Telegram 状态..."
                if [ "$TG_ST" == "true" ]; then
                    jq '.config.enable_telegram = false' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                    msg_warn "Telegram -> OFF"
                else
                    jq '.config.enable_telegram = true' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                    msg_ok "Telegram -> ON"
                fi
                sync; run_restart
                echo -e "${GRAY}按任意键刷新界面...${NC}"; read -n 1 -s -r
                ;;
            0) return ;;
            *) ;;
        esac
    done
}

run_manage_vip() {
    check_service_exists
    check_jq
    
    while true; do
        echo -e "\n${CYAN}--- VIP 专线监控管理 ---${NC}"
        local VIPS=$(jq -r '.config.vip_threads[]' "$CONFIG_FILE" 2>/dev/null || echo "")
        local COUNT=0
        if [ -n "$VIPS" ]; then
            echo -e "\n当前监控列表:"
            IFS=$'\n'
            for url in $VIPS; do
                echo -e "  [${GREEN}$COUNT${NC}] $url"
                COUNT=$((COUNT+1))
            done
            unset IFS
        else
            echo -e "\n(列表为空)"
        fi
        echo -e "\n${YELLOW}操作选项:${NC} 1.添加 2.删除 0.返回"
        read -p "请选择: " OPT
        case "$OPT" in
            1)
                read -p "URL: " NEW_URL
                if [[ "$NEW_URL" == http* ]]; then
                    jq 'if .config.vip_threads == null then .config.vip_threads = [] else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                    jq --arg url "$NEW_URL" '.config.vip_threads += [$url]' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                    msg_ok "添加成功"
                fi
                ;;
            2)
                read -p "序号: " DEL_IDX
                if [[ "$DEL_IDX" =~ ^[0-9]+$ ]] && [ "$DEL_IDX" -lt "$COUNT" ]; then
                    jq "del(.config.vip_threads[$DEL_IDX])" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                    msg_ok "删除成功"
                fi
                ;;
            0) return ;;
        esac
    done
}

run_manage_users() {
    check_service_exists
    check_jq
    while true; do
        echo -e "\n${CYAN}--- 指定用户监控 ---${NC}"
        local USERS=$(jq -r '.config.monitored_usernames[]' "$CONFIG_FILE" 2>/dev/null || echo "")
        local COUNT=0
        if [ -n "$USERS" ]; then
            echo -e "\n当前用户列表:"
            IFS=$'\n'
            for u in $USERS; do echo -e "  [${GREEN}$COUNT${NC}] $u"; COUNT=$((COUNT+1)); done
            unset IFS
        else echo -e "\n(列表为空)"; fi
        echo -e "\n${YELLOW}操作选项:${NC} 1.添加 2.删除 0.返回"
        read -p "请选择: " OPT
        case "$OPT" in
            1)
                read -p "用户名: " NEW_USER
                if [ -n "$NEW_USER" ]; then
                    jq 'if .config.monitored_usernames == null then .config.monitored_usernames = [] else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                    jq --arg u "$NEW_USER" '.config.monitored_usernames += [$u]' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                    msg_ok "添加成功"
                fi
                ;;
            2)
                read -p "序号: " DEL_IDX
                if [[ "$DEL_IDX" =~ ^[0-9]+$ ]] && [ "$DEL_IDX" -lt "$COUNT" ]; then
                    jq "del(.config.monitored_usernames[$DEL_IDX])" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                    msg_ok "删除成功"
                fi
                ;;
            0) return ;;
        esac
    done
}

run_manage_roles() {
    check_service_exists
    check_jq
    # Ensure field exists
    jq 'if .config.monitored_roles == null then .config.monitored_roles = ["creator","provider","top_host","host_rep","admin"] else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

    while true; do
        echo -e "\n${CYAN}--- 监控角色设置 ---${NC}"
        has_role() { jq -e --arg r "$1" '.config.monitored_roles | index($r)' "$CONFIG_FILE" >/dev/null 2>&1; }
        
        echo -e "\n当前状态:"
        if has_role "creator"; then S="✅"; else S="❌"; fi; echo -e "  1. $S 楼主 (Creator)"
        if has_role "provider"; then S="✅"; else S="❌"; fi; echo -e "  2. $S 认证商家 (Provider)"
        if has_role "top_host"; then S="✅"; else S="❌"; fi; echo -e "  3. $S Top Host"
        if has_role "host_rep"; then S="✅"; else S="❌"; fi; echo -e "  4. $S Host Rep"
        if has_role "admin"; then S="✅"; else S="❌"; fi; echo -e "  5. $S 管理员 (Administrator)"
        if has_role "other"; then S="✅"; else S="❌"; fi; echo -e "  6. $S 其他 (All Others) ${RED}*全量监控 (慎开)${NC}"
        
        echo -e "\n${YELLOW}操作选项 (1-6 切换, 0 返回):${NC}"
        read -p "请选择: " OPT
        target=""
        case "$OPT" in
            1) target="creator" ;; 2) target="provider" ;; 3) target="top_host" ;;
            4) target="host_rep" ;; 5) target="admin" ;; 6) target="other" ;;
            0) return ;; *) continue ;;
        esac
        
        if [ -n "$target" ]; then
            if has_role "$target"; then
                jq --arg r "$target" '.config.monitored_roles -= [$r]' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                msg_warn "已禁用: $target"
            else
                jq --arg r "$target" '.config.monitored_roles += [$r]' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                msg_ok "已启用: $target"
            fi
        fi
    done
}

run_manage_prompts() {
    check_service_exists
    check_jq

    _edit_prompt_text() {
        local KEY="$1"
        local LABEL="$2"
        local TMP_FILE="/tmp/fm_prompt_edit.txt"
        
        # Extract current prompt
        jq -r ".config.$KEY" "$CONFIG_FILE" > "$TMP_FILE"
        
        echo -e "\n${YELLOW}即将打开编辑器 (nano) 修改 [$LABEL]。${NC}"
        echo -e "${GRAY}修改完成后，按 Ctrl+O 保存，Ctrl+X 退出。${NC}"
        read -n 1 -s -r -p "按任意键开始..."
        
        ${EDITOR:-nano} "$TMP_FILE"
        
        if [ -f "$TMP_FILE" ]; then
            local NEW_CONTENT=$(cat "$TMP_FILE")
            # 移除 Windows 回车符，防止 JSON 报错
            NEW_CONTENT="${NEW_CONTENT//\r/}"
            
            if [ -n "$NEW_CONTENT" ]; then
                jq --arg p "$NEW_CONTENT" ".config.$KEY = \$p" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                msg_ok "[$LABEL] 更新成功！"
                rm -f "$TMP_FILE"
                echo -e "需要重启服务生效。正在重启..."
                run_restart
            else
                msg_warn "内容为空，未修改。"
            fi
        else
            msg_err "临时文件丢失，取消操作。"
        fi
    }

    _reset_prompts() {
        echo -e "\n${RED}⚠️ 警告: 将重置所有提示词为默认值！${NC}"
        read -p "确认重置? (y/n): " CONFIRM
        if [[ "$CONFIRM" != "y" ]]; then return; fi
        
        # 重新定义默认 Prompt (注意：这里使用纯 Unix 换行)
        local DEF_THREAD="你是一个中文VPS助手。请分析此促销信息。
目标：提取文中提到的所有VPS套餐信息。
规则：
1. 不要使用 Markdown 代码块。
2. 不要使用 HTML 标签。
3. 必须严格按照以下格式输出：

[促销] <商家名称>
配置：<CPU> <内存> <硬盘> <带宽/流量>
价格：<价格>
链接：<购买链接1>
链接：<购买链接2> (如果有多个链接，请务必换行并在每行开头重复“链接：”)
优惠码：<优惠码> (没有则不写)
总结：<简短摘要>

(如果有多个套餐，请空一行后重复上述格式)"

        local DEF_FILTER="你是一个VPS优惠分析师。请分析回复。
规则：
1. 忽略订单号/晒单/求翻倍(Double Bandwidth)。
2. 忽略无关闲聊。
3. 仅提取新优惠。

**格式要求（纯文本，不要Markdown）**：

[促销] <商家名称>
配置：<核心> <内存> <硬盘> <带宽>
价格：<价格>
链接：<链接> (如果有多个，请换行重复“链接：”前缀)
优惠码：<优惠码> (可选)
总结：<简短摘要>"

        jq --arg p "$DEF_THREAD" --arg f "$DEF_FILTER" \
           '.config.thread_prompt = $p | .config.filter_prompt = $f' \
           "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        
        msg_ok "提示词已重置。正在重启..."
        run_restart
    }

    while true; do
        clear
        echo -e "${BLUE}================================================================${NC}"
        echo -e " ${CYAN}AI 提示词管理 (Prompt Settings)${NC}"
        echo -e "${BLUE}================================================================${NC}"
        echo -e "  1. 修改: 帖子摘要提示词 (Thread Summary Prompt)"
        echo -e "     ${GRAY}* 用于生成新帖子的总结内容${NC}"
        echo -e "  2. 修改: 回复过滤提示词 (Comment Filter Prompt)"
        echo -e "     ${GRAY}* 用于分析回帖，提取补货或优惠信息${NC}"
        echo -e "${GRAY}----------------------------------------------------------------${NC}"
        echo -e "  3. 重置: 恢复默认提示词 (Reset to Default)"
        echo -e "  0. 返回上级菜单"
        echo -e "${BLUE}================================================================${NC}"
        
        read -p "请选择: " OPT
        case "$OPT" in
            1) _edit_prompt_text "thread_prompt" "帖子摘要提示词"; read -n 1 -s -r -p "..." ;;
            2) _edit_prompt_text "filter_prompt" "回复过滤提示词"; read -n 1 -s -r -p "..." ;;
            3) _reset_prompts; read -n 1 -s -r -p "..." ;;
            0) return ;;
            *) ;;
        esac
    done
}

run_ai_switch() {
    check_service_exists
    check_jq
    
    local CUR_PROVIDER=$(jq -r '.config.ai_provider // "gemini"' "$CONFIG_FILE")
    local CUR_G_KEY=$(jq -r '.config.gemini_api_key' "$CONFIG_FILE")
    local CUR_G_MODEL=$(jq -r '.config.model // "gemini-2.0-flash-lite"' "$CONFIG_FILE")
    
    local CUR_CF_ACC=$(jq -r '.config.cf_account_id // ""' "$CONFIG_FILE")
    local CUR_CF_TOK=$(jq -r '.config.cf_api_token // ""' "$CONFIG_FILE")
    local CUR_CF_MODEL=$(jq -r '.config.cf_model // "@cf/meta/llama-3.1-8b-instruct"' "$CONFIG_FILE")

    echo -e "\n${CYAN}--- AI 引擎切换 ---${NC}"
    echo -e "当前: ${GREEN}${CUR_PROVIDER^^}${NC}"

    echo "  1. Google Gemini"
    echo "  2. Cloudflare Workers AI"
    echo "  0. 返回"
    read -p "选择: " SEL
    
    case "$SEL" in
        1)
            read -p "API Key (回车保留): " N_KEY
            read -p "Model (回车保留 $CUR_G_MODEL): " N_MODEL
            [ -z "$N_KEY" ] && N_KEY="$CUR_G_KEY"
            [ -z "$N_MODEL" ] && N_MODEL="$CUR_G_MODEL"
            jq --arg k "$N_KEY" --arg m "$N_MODEL" \
               '.config.ai_provider="gemini" | .config.gemini_api_key=$k | .config.model=$m' \
               "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
            msg_ok "已切换至 Gemini，重启中..."
            run_restart
            ;;
        2)
            read -p "Account ID (回车保留): " N_ACC
            read -p "API Token (回车保留): " N_TOK
            read -p "Model (回车保留 $CUR_CF_MODEL): " N_MODEL
            [ -z "$N_ACC" ] && N_ACC="$CUR_CF_ACC"
            [ -z "$N_TOK" ] && N_TOK="$CUR_CF_TOK"
            [ -z "$N_MODEL" ] && N_MODEL="$CUR_CF_MODEL"
            jq --arg a "$N_ACC" --arg t "$N_TOK" --arg m "$N_MODEL" \
               '.config.ai_provider="workers" | .config.cf_account_id=$a | .config.cf_api_token=$t | .config.cf_model=$m' \
               "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
            msg_ok "已切换至 Workers AI，重启中..."
            run_restart
            ;;
        *) return ;;
    esac
}

run_edit_config() {
    check_service_exists
    check_jq
    echo "--- 修改基础配置 (直接回车保留) ---"
    
    local C_PT=$(jq -r '.config.pushplus_token' "$CONFIG_FILE")
    local C_TG_TOK=$(jq -r '.config.telegram_bot_token // ""' "$CONFIG_FILE")
    local C_TG_ID=$(jq -r '.config.telegram_chat_id // ""' "$CONFIG_FILE")

    read -p "Pushplus Token: " N_PT
    read -p "Telegram Bot Token: " N_TG_TOK
    read -p "Telegram Chat ID: " N_TG_ID
    
    [ -z "$N_PT" ] && N_PT="$C_PT"
    [ -z "$N_TG_TOK" ] && N_TG_TOK="$C_TG_TOK"
    [ -z "$N_TG_ID" ] && N_TG_ID="$C_TG_ID"

    jq --arg a "$N_PT" --arg d "$N_TG_TOK" --arg e "$N_TG_ID" \
       '.config.pushplus_token=$a|.config.telegram_bot_token=$d|.config.telegram_chat_id=$e' \
       "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    
    msg_ok "配置已更新，重启中..."
    run_restart
}

run_edit_frequency() {
    check_service_exists
    check_jq
    local CUR=$(jq -r '.config.frequency' "$CONFIG_FILE")
    echo "当前: $CUR 秒"
    read -p "新间隔 (秒): " NEW
    if ! [[ "$NEW" =~ ^[0-9]+$ ]]; then msg_err "无效数字"; return 1; fi
    jq --argjson v "$NEW" '.config.frequency=$v' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    run_restart
}

run_edit_threads() {
    check_service_exists
    check_jq
    local CUR=$(jq -r '.config.max_workers // 5' "$CONFIG_FILE")
    echo "当前: $CUR"
    read -p "新线程数 (1-100): " NEW
    if ! [[ "$NEW" =~ ^[0-9]+$ ]] || [ "$NEW" -lt 1 ] || [ "$NEW" -gt 100 ]; then msg_err "无效数字"; return 1; fi
    jq --argjson v "$NEW" '.config.max_workers=$v' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    run_restart
}

run_status() {
    check_service_exists
    systemctl status $SERVICE_NAME --no-pager
    if [ -f "$HEARTBEAT_FILE" ]; then
        local DIFF=$(($(date +%s) - $(cat "$HEARTBEAT_FILE" | tr -cd '0-9' || echo "0")))
        echo -e "\n--- 心跳: ${GREEN}$DIFF 秒前${NC}"
    fi
}

run_logs() {
    check_service_exists
    kill_zombie_loggers
    msg_info "正在加载实时日志..."
    echo -e "${YELLOW}👉 按 '0' 返回主菜单 | 按 'Ctrl+C' 退出脚本${NC}"
    echo -e "${GRAY}--------------------------------------------------${NC}"
    
    local LOG_PID=0
    # 后台运行日志流
    journalctl -u $SERVICE_NAME -f -n 50 --output cat &
    LOG_PID=$!
    
    cleanup() {
        if [ "$LOG_PID" -gt 0 ]; then
            kill "$LOG_PID" >/dev/null 2>&1 || true
            wait "$LOG_PID" 2>/dev/null || true
        fi
    }
    
    trap 'trap - EXIT; cleanup; echo -e "\n${GREEN}[Exit] 已退出脚本 (回到Shell)${NC}"; exit 0' SIGINT
    trap cleanup EXIT

    while true; do
        read -n 1 -s -r key
        if [[ "$key" == "0" ]]; then
            break
        fi
    done
    
    cleanup
    trap - SIGINT EXIT
    
    echo -e "\n${GREEN}[OK] 返回主菜单...${NC}"
    sleep 0.5
}

run_view_history() {
    check_service_exists
    local PY_SCRIPT="
import pymongo, os
from datetime import datetime
try:
    client = pymongo.MongoClient(os.getenv('MONGO_HOST', 'mongodb://localhost:27017/'))
    logs = list(client['forum_monitor']['push_logs'].find().sort('created_at', -1).limit(20))
    print('-'*85 + f'\n| {\"Time\":<19} | {\"Type\":<8} | {\"Title\":<50} |\n' + '-'*85)
    for l in logs:
        ts = l.get('created_at', datetime.now()).strftime('%Y-%m-%d %H:%M:%S')
        t = l.get('title', 'No Title')[:45]
        print(f'| {ts:<19} | {l.get(\"type\", \"UNK\"):<8} | {t:<50} |')
    print('-'*85)
except: pass
"
    "$VENV_DIR/bin/python" -c "$PY_SCRIPT"
}

run_repush_active() {
    check_service_exists
    msg_info "正在重推 (Single-Thread)..."
    local PY_SCRIPT="
import pymongo, os, sys, time
from datetime import datetime, timezone, timedelta
sys.path.append('$APP_DIR')
from core import ForumMonitor, SHANGHAI

try:
    m = ForumMonitor('$CONFIG_FILE')
    cursor = m.db['threads'].find().sort('pub_date', -1).limit(5)
    print('Scanning...')
    for t in cursor:
        print(f' -> Repushing: {t.get(\"title\")[:30]}')
        
        raw_summary = m.get_summarize_from_ai(t.get('description', ''))
        html_summary = m.markdown_to_html(raw_summary)
        
        pub_date = t['pub_date']
        if pub_date.tzinfo is None: pub_date = pub_date.replace(tzinfo=timezone.utc)
        time_str = pub_date.astimezone(SHANGHAI).strftime('%Y-%m-%d %H:%M')
        
        safe_title = t['title'].replace('<', '&lt;').replace('>', '&gt;')
        safe_creator = t.get('creator', 'Unknown').replace('<', '&lt;').replace('>', '&gt;')
        model_n = m.config.get('model') if m.ai_provider == 'gemini' else m.config.get('cf_model')

        msg_content = (
            f'<b>🟡 [Repush] {safe_title}</b>\n'
            f'👤 {safe_creator} | 🕒 {time_str} | 🤖 {model_n}\n'
            f'{\"-\"*20}\n'
            f'{html_summary}\n'
            f'{\"-\"*20}\n'
            f'原文链接: {t[\"link\"]}'
        )
        
        m.notifier.send_html_message(f'🟡 [Repush] {safe_title}', msg_content)
        time.sleep(2)
except Exception as e: print(f'Error: {e}')
"
    "$VENV_DIR/bin/python" -c "$PY_SCRIPT"
}

run_test_push() {
    check_service_exists
    msg_info "正在发送全真模拟通知..."
    local PY_CMD="
import sys
sys.path.append('$APP_DIR')
from send import NotificationSender
from datetime import datetime

s = NotificationSender('$CONFIG_FILE')
time_str = datetime.now().strftime('%Y-%m-%d %H:%M')

title = '🟢 [TEST] 模拟 VPS 优惠通知'
content = (
    f'<b>🔵 [回复] [TestUser] 帖子标题测试</b>\n'
    f'👤 TestUser | 🕒 {time_str} | 🤖 Mock-Model-v1\n'
    f'{\"-\"*20}\n'
    f'[促销] FiberState\n'
    f'配置：AMD Ryzen 7 5700G（8核16线程） 64GB内存 1TB三星NVMe\n'
    f'价格：\$49.95/月 \$44.95（限时优惠）\n'
    f'链接：https://billing.fiberstate.com/index.php?rp=/store/bare-metal/ryzen-7\n'
    f'链接：https://example.com/second-link\n'
    f'优惠码：CYBR7-2025\n'
    f'总结：FiberState推出Cyber Week限时促销...\n\n'
    f'原文链接: https://lowendtalk.com/test'
)
content_html = content.replace('\n', '<br>')

s.send_html_message(title, content_html)
"
    "$VENV_DIR/bin/python" -c "$PY_CMD"
}

run_test_ai() {
    check_service_exists
    msg_info "正在测试 AI..."
    local CMD="import sys; sys.path.append('$APP_DIR'); from core import ForumMonitor; print(ForumMonitor(config_path='$CONFIG_FILE').get_filter_from_ai(\"Test message.\"))"
    local RES=$("$VENV_DIR/bin/python" -c "$CMD" 2>&1)
    echo "API Response: $RES"
    if [[ "$RES" == *"FALSE"* ]] || [[ -n "$RES" ]]; then msg_ok "AI 响应成功"; else msg_err "AI 响应为空/失败"; fi
}

run_update() {
    local P=$(realpath "$0")
    local T="${P}.new"
    msg_info "正在下载最新脚本..."
    if curl -s -L "$UPDATE_URL" -o "$T"; then
        if bash -n "$T"; then
            chmod +x "$T"; mv "$T" "$P"
            msg_ok "更新成功，重新加载中..."
            sleep 1
            exec "$P" "--post-update"
        else
            msg_err "校验失败"
            rm -f "$T"
        fi
    else
        msg_err "下载失败"
    fi
}

run_monitor_logic() {
    check_jq
    if ! systemctl is-active --quiet $SERVICE_NAME; then return 0; fi
    if [ ! -f "$HEARTBEAT_FILE" ]; then return 0; fi
    # 安全读取心跳
    local LAST=$(cat "$HEARTBEAT_FILE" | tr -cd '0-9')
    [ -z "$LAST" ] && LAST="0"
    
    local FREQ=$(jq -r '.config.frequency // 600' "$CONFIG_FILE" 2>/dev/null || echo "600")
    local DIFF=$(($(date +%s) - LAST))
    
    if [ "$DIFF" -gt "$(($FREQ + 300))" ]; then
        echo "$(date): [Watchdog] 服务僵死 (Diff: $DIFF)，正在重启" >> "$RESTART_LOG_FILE"
        systemctl restart $SERVICE_NAME
    fi
}

run_setup_keepalive() {
    msg_info "配置 Crontab 保活..."
    local CMD="*/5 * * * * $(realpath "$0") monitor >> $APP_DIR/monitor.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "monitor"; echo "$CMD") | crontab -
    msg_ok "已添加"
}

run_uninstall() {
    msg_warn "正在卸载..."
    crontab -l 2>/dev/null | grep -v "monitor" | crontab -
    systemctl stop $SERVICE_NAME mongod || true
    systemctl disable $SERVICE_NAME mongod || true
    rm -f "$SYSTEMD_SERVICE_FILE"
    systemctl daemon-reload
    rm -rf "$APP_DIR" "$SHORTCUT_PATH"
    msg_ok "卸载完成"
}

run_update_config_prompt() {
    if [ -f "$CONFIG_FILE" ]; then
        jq 'if .config.vip_threads == null then .config.vip_threads = [] else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        jq 'if .config.monitored_usernames == null then .config.monitored_usernames = [] else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        jq 'if .config.monitored_roles == null then .config.monitored_roles = ["creator","provider","top_host","host_rep","administrator"] else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        
        jq 'if .config.enable_pushplus == null then .config.enable_pushplus = true else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        jq 'if .config.enable_telegram == null then .config.enable_telegram = true else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

        jq 'if .config.ai_provider == null then .config.ai_provider = "gemini" else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        jq 'if .config.cf_model == null then .config.cf_model = "@cf/meta/llama-3.1-8b-instruct" else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

        # --- UPDATED PROMPT: 定义时移除潜在的 \r (虽然这里是 Linux 环境，但为了安全)
        local NEW_THREAD_PROMPT="你是一个中文VPS助手。请分析此促销信息。
目标：提取文中提到的所有VPS套餐信息。
规则：
1. 不要使用 Markdown 代码块。
2. 不要使用 HTML 标签。
3. 必须严格按照以下格式输出：

[促销] <商家名称>
配置：<CPU> <内存> <硬盘> <带宽/流量>
价格：<价格>
链接：<购买链接1>
链接：<购买链接2> (如果有多个链接，请务必换行并在每行开头重复“链接：”)
优惠码：<优惠码> (没有则不写)
总结：<简短摘要>

(如果有多个套餐，请空一行后重复上述格式)"

        # UPDATED FILTER PROMPT
        local FILTER="你是一个VPS优惠分析师。请分析回复。
规则：
1. 忽略订单号/晒单/求翻倍(Double Bandwidth)。
2. 忽略无关闲聊。
3. 仅提取新优惠。

**格式要求（纯文本，不要Markdown）**：

[促销] <商家名称>
配置：<核心> <内存> <硬盘> <带宽>
价格：<价格>
链接：<链接> (如果有多个，请换行重复“链接：”前缀)
优惠码：<优惠码> (可选)
总结：<简短摘要>"
        
        # 强制清除 \r
        NEW_THREAD_PROMPT="${NEW_THREAD_PROMPT//\r/}"
        FILTER="${FILTER//\r/}"

        jq --arg p "$NEW_THREAD_PROMPT" --arg f "$FILTER" \
           'if .config.thread_prompt == null then .config.thread_prompt = $p else . end | if .config.filter_prompt == null then .config.filter_prompt = $f else . end' \
           "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    fi
}

# --- 核心代码写入 (Python) ---
_write_python_files_and_deps() {
    msg_info "写入 Python 核心代码 (v79: StableFix)..."
    
    cat <<'EOF' > "$APP_DIR/$PYTHON_SCRIPT_NAME"
import json
import time
import requests
import cloudscraper
from bs4 import BeautifulSoup
from datetime import datetime, timedelta, timezone
from send import NotificationSender
import os
import sys
import re
import fcntl
import psutil
import google.generativeai as genai
from pymongo import MongoClient, errors
from concurrent.futures import ThreadPoolExecutor, as_completed

# 颜色定义
GREEN = '\033[0;32m'
YELLOW = '\033[0;33m'
RED = '\033[0;31m'
CYAN = '\033[0;36m'
BLUE = '\033[0;34m'
NC = '\033[0m'
GRAY = '\033[0;90m'
WHITE = '\033[1;37m'
MAGENTA = '\033[0;35m'

SHANGHAI = timezone(timedelta(hours=8))

def log(msg, color=NC, icon=""):
    timestamp = datetime.now(SHANGHAI).strftime("%H:%M:%S")
    prefix = f"{icon} " if icon else ""
    try:
        print(f"{GRAY}[{timestamp}]{NC} {color}{prefix}{msg}{NC}")
        sys.stdout.flush()
    except: pass

class ForumMonitor:
    def __init__(self, config_path='data/config.json'):
        # --- SELF-HEALING SINGLETON ---
        self.lock_file = open('/tmp/forum_monitor.lock', 'w')
        try:
            fcntl.lockf(self.lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except IOError:
            log("⚡ Duplicate instance detected! Killing zombies...", YELLOW)
            self.kill_other_instances()
            time.sleep(2)
            try:
                fcntl.lockf(self.lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
                log("✅ Zombies killed. Taking over.", GREEN)
            except:
                log("❌ Failed to acquire lock. Exiting.", RED)
                sys.exit(1)
        # ------------------------------

        self.config_path = config_path
        self.mongo_host = os.getenv("MONGO_HOST", 'mongodb://localhost:27017/')
        self.load_config()

        self.mongo_client = MongoClient(self.mongo_host) 
        self.db = self.mongo_client['forum_monitor']
        self.threads_collection = self.db['threads']
        self.comments_collection = self.db['comments']
        self.push_logs = self.db['push_logs']
        
        self.processed_urls_this_cycle = set()
        
        self.scraper = cloudscraper.create_scraper(
            browser={'browser': 'chrome', 'platform': 'windows', 'desktop': True}
        )
        self.scraper.headers.update({
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'en-US,en;q=0.9',
            'Referer': 'https://lowendtalk.com/',
        })

        self.ai_provider = self.config.get('ai_provider', 'gemini')
        self.thread_prompt = self.config.get('thread_prompt', '')
        self.filter_prompt = self.config.get('filter_prompt', '')

        if self.ai_provider == 'gemini':
            try:
                api_key = self.config.get('gemini_api_key')
                model_name = self.config.get('model', 'gemini-2.0-flash-lite')
                if api_key:
                    genai.configure(api_key=api_key)
                    self.model_summary = genai.GenerativeModel(model_name, system_instruction=self.thread_prompt)
                    self.model_filter = genai.GenerativeModel(model_name, system_instruction=self.filter_prompt)
                    log(f"AI Engine: Gemini ({model_name})", GREEN, "🧠")
            except Exception as e: log(f"Gemini Init Error: {e}", RED)
        elif self.ai_provider == 'workers':
            self.cf_account = self.config.get('cf_account_id')
            self.cf_token = self.config.get('cf_api_token')
            self.cf_model = self.config.get('cf_model', '@cf/meta/llama-3.1-8b-instruct')
            if self.cf_account and self.cf_token:
                log(f"AI Engine: Workers AI ({self.cf_model})", GREEN, "🧠")
            else:
                log("AI Engine: Workers AI Config Missing!", RED)

        try:
            self.threads_collection.create_index('link', unique=True)
            self.comments_collection.create_index('comment_id', unique=True)
            self.push_logs.create_index('created_at')
        except: pass

    def kill_other_instances(self):
        current_pid = os.getpid()
        for proc in psutil.process_iter(['pid', 'name', 'cmdline']):
            try:
                if proc.info['pid'] == current_pid: continue
                cmdline = proc.info.get('cmdline', [])
                if cmdline and 'core.py' in ' '.join(cmdline):
                    log(f"   -> Killing zombie PID: {proc.info['pid']}", GRAY)
                    proc.kill()
            except: pass

    def load_config(self):
        try:
            if not os.path.exists(self.config_path):
                # No example.json copy, just use empty
                self.config = {}
            with open(self.config_path, 'r') as f:
                self.config = json.load(f)['config']
                self.notifier = NotificationSender(self.config_path)
        except: self.config = {}

    def update_heartbeat(self):
        try:
            with open('data/heartbeat.txt', 'w') as f:
                f.write(str(int(time.time())))
        except: pass

    def log_push_history(self, p_type, title, url):
        try:
            self.push_logs.insert_one({
                'type': p_type, 'title': title, 'url': url,
                'created_at': datetime.now(SHANGHAI)
            })
        except: pass

    def generate_ai_content(self, system_prompt, user_content, gemini_model_instance=None):
        retries = 5
        delay = 10
        for i in range(retries):
            try:
                time.sleep(1) 
                if self.ai_provider == 'gemini':
                    if gemini_model_instance:
                        response = gemini_model_instance.generate_content(user_content)
                        return response.text
                    else: return "Gemini Not Initialized"
                elif self.ai_provider == 'workers':
                    url = f"https://api.cloudflare.com/client/v4/accounts/{self.cf_account}/ai/run/{self.cf_model}"
                    headers = {"Authorization": f"Bearer {self.cf_token}"}
                    payload = {"messages": [{"role": "system", "content": system_prompt}, {"role": "user", "content": user_content}]}
                    resp = requests.post(url, headers=headers, json=payload, timeout=30)
                    if resp.status_code == 200:
                        return resp.json().get("result", {}).get("response", "FALSE")
                    else: raise Exception(f"CF API Error: {resp.status_code} {resp.text}")
            except Exception as e:
                if "429" in str(e) or "quota" in str(e).lower():
                    log(f"⚠️ AI Rate Limit (429). Retrying... ({i+1}/{retries})", YELLOW)
                    time.sleep(delay); delay = int(delay * 1.5)
                else:
                    log(f"❌ AI Error: {e}", RED); return "FALSE"
        return "FALSE"

    def get_summarize_from_ai(self, description):
        try: 
            gemini_obj = self.model_summary if self.ai_provider == 'gemini' else None
            return self.generate_ai_content(self.thread_prompt, description, gemini_obj).strip()
        except: return "AI Error"

    def get_filter_from_ai(self, description):
        try:
            gemini_obj = self.model_filter if self.ai_provider == 'gemini' else None
            text = self.generate_ai_content(self.filter_prompt, description, gemini_obj).strip()
            return text
        except: return "FALSE"

    def markdown_to_html(self, text):
        text = text.replace("```html", "").replace("```", "")
        text = re.sub(r'\*\*(.*?)\*\*', r'<b>\1</b>', text)
        text = re.sub(r'</?(span|div|p|font|h[1-6])[^>]*>', '', text, flags=re.IGNORECASE)
        text = text.replace('&', '&amp;')
        text = text.replace('<', '&lt;')
        text = text.replace('>', '&gt;')
        text = text.replace('&lt;b&gt;', '<b>').replace('&lt;/b&gt;', '</b>')
        text = text.replace('&lt;a href="', '<a href="').replace('"&gt;', '">').replace('&lt;/a&gt;', '</a>')
        text = text.replace('\n', '<br>')
        return text.strip()

    def handle_thread(self, thread_data, extracted_links):
        try:
            self.threads_collection.insert_one(thread_data)
            now_sh = datetime.now(SHANGHAI)
            pub_date_sh = thread_data['pub_date'].astimezone(SHANGHAI)

            if (now_sh - pub_date_sh).total_seconds() <= 86400:
                log(f"AI 正在摘要: {thread_data['title'][:20]}...", YELLOW, "🤖")
                raw_summary = self.get_summarize_from_ai(thread_data['description'])
                html_summary = self.markdown_to_html(raw_summary)
                html_summary = html_summary.replace("[ORDER_LINK_HERE]", "")

                time_str = pub_date_sh.strftime('%Y-%m-%d %H:%M')
                safe_title = thread_data['title'].replace('<', '&lt;').replace('>', '&gt;')
                safe_creator = thread_data['creator'].replace('<', '&lt;').replace('>', '&gt;')
                model_n = self.config.get('model') if self.ai_provider == 'gemini' else self.config.get('cf_model')

                msg_content = (
                    f"<b>🟢 [新帖] {safe_title}</b>\n"
                    f"👤 {safe_creator} | 🕒 {time_str} | 🤖 {model_n}\n"
                    f"{'-'*20}\n"
                    f"{html_summary}\n" 
                    f"{'-'*20}\n"
                    f"原文链接: {thread_data['link']}"
                )
                msg_content = msg_content.replace('\n', '<br>')
                
                if self.notifier.send_html_message(f"🟢 [新帖] {safe_title}", msg_content):
                    self.log_push_history("thread", thread_data['title'], thread_data['link'])

            return True 
        except errors.DuplicateKeyError: return False
        except: return False

    def handle_comment(self, comment_data, thread_data, created_at_sh):
        try:
            self.comments_collection.insert_one(comment_data)
            log(f"   ✅ [新回复] {comment_data['author']} (活跃中...)", GREEN)
            
            if not comment_data['message'].strip(): return

            # --- [HARD FILTER] 强力过滤系统 (v76/v77) ---
            msg_lower = comment_data['message'].lower()

            # 1. 拦截翻倍/晒单
            if ("order" in msg_lower or "invoice" in msg_lower) and ("double" in msg_lower or "bandwidth" in msg_lower):
                log(f"      🚫 [Filter] 拦截翻倍/晒单", GRAY); return
            
            # 2. 拦截纯订单号
            if len(msg_lower) < 60 and (("order" in msg_lower and "#" in msg_lower) or "invoice" in msg_lower):
                log(f"      🚫 [Filter] 拦截纯订单号", GRAY); return

            # 3. 拦截无意义短回复
            junk_words = ["pm sent", "check pm", "sent you a pm", "replied", "ticket opened", "check ticket", "thanks", "thx", "good luck", "nice offer", "upvoted", "support", "ticket #", "dm sent"]
            if len(msg_lower) < 50 and any(k in msg_lower for k in junk_words):
                 log(f"      🚫 [Filter] 拦截水贴/工单回复", GRAY); return
            
            # 4. 极短纯文本拦截
            if len(msg_lower) < 10 and not any(c.isdigit() for c in msg_lower):
                 log(f"      🚫 [Filter] 拦截极短回复", GRAY); return
            # ---------------------------------------------

            ai_resp = self.get_filter_from_ai(comment_data['message'])
            upper_resp = ai_resp.upper()
            
            if "FALSE" not in upper_resp and "无法分析" not in ai_resp and "CANNOT" not in upper_resp:
                log(f"      🚀 关键词匹配! 推送中...", GREEN)
                ai_resp_html = self.markdown_to_html(ai_resp)
                
                tp = thread_data.get('creator', 'Unknown').replace('<', '&lt;').replace('>', '&gt;')
                ra = comment_data['author'].replace('<', '&lt;').replace('>', '&gt;')
                tt = thread_data.get('title', 'Unknown').replace('<', '&lt;').replace('>', '&gt;')
                model_n = self.config.get('model') if self.ai_provider == 'gemini' else self.config.get('cf_model')
                time_str = created_at_sh.strftime('%H:%M')
                
                is_op = (comment_data['author'] == thread_data['creator'])
                type_label = "回复" if is_op else "插播"
                type_icon = "🔵" if is_op else "🔴"
                
                push_title = f"{type_icon} [{type_label}] [{tp}] {tt}"
                
                msg_content = (
                    f"<b>{push_title}</b>\n"
                    f"👤 {ra} | 🕒 {time_str} | 🤖 {model_n}\n"
                    f"{'-'*20}\n"
                    f"{ai_resp_html}\n"
                    f"{'-'*20}\n"
                    f"原文链接: {comment_data['url']}"
                )
                msg_content = msg_content.replace('\n', '<br>')
                
                if self.notifier.send_html_message(push_title, msg_content):
                    self.log_push_history("reply", f"{push_title}", comment_data['url'])
                    
        except errors.DuplicateKeyError: pass 
        except: pass

    def parse_let_comment(self, html_content, thread_data):
        soup = BeautifulSoup(html_content, 'html.parser')
        comments = soup.find_all('li', class_='ItemComment')
        now_sh = datetime.now(SHANGHAI)
        enabled_roles = self.config.get('monitored_roles', ["creator", "provider", "top_host", "host_rep", "admin"])
        target_usernames = self.config.get('monitored_usernames', [])
        found_recent = False

        for comment in comments:
            try:
                date_str = comment.find('time')['datetime']
                created_at_aware = datetime.strptime(date_str, "%Y-%m-%dT%H:%M:%S%z")
                created_at_sh = created_at_aware.astimezone(SHANGHAI)
                if (now_sh - created_at_sh).total_seconds() > 86400: continue 
                found_recent = True
                
                author_tag = comment.find('a', class_='Username')
                if not author_tag: continue
                author_name = author_tag.text
                
                role_hits = []
                is_target_user = (author_name in target_usernames)
                if author_name == thread_data['creator']: role_hits.append('creator')
                class_str = " ".join(comment.get('class', [])).lower()
                if 'role_patronprovider' in class_str or 'role_provider' in class_str: role_hits.append('provider')
                if 'role_tophost' in class_str: role_hits.append('top_host')
                if 'role_hostrep' in class_str: role_hits.append('host_rep')
                if 'role_administrator' in class_str or author_name.lower() == 'administrator': role_hits.append('admin')
                if not role_hits: role_hits.append('other')
                
                if not (any(r in enabled_roles for r in role_hits) or is_target_user): continue

                comment_id = comment['id'].replace('Comment_', '')
                msg_div = comment.find('div', class_='Message')
                if msg_div:
                    for quote in msg_div.find_all('blockquote'): quote.decompose()
                    
                    for a in msg_div.find_all('a', href=True):
                        url = a['href']
                        if "lowendtalk.com" not in url:
                             a.replace_with(f" {a.get_text(strip=True)} (Link: {url}) ")
                    
                    message = msg_div.get_text(separator=' ', strip=True)
                else: message = ""
                
                if not message or len(message) < 2: continue

                permalink_url = f"https://lowendtalk.com/discussion/comment/{comment_id}/#Comment_{comment_id}"
                c_data = {'comment_id': comment_id, 'thread_link': thread_data['link'], 'author': author_name, 'message': message, 'created_at': created_at_aware, 'url': permalink_url}
                self.handle_comment(c_data, thread_data, created_at_sh)
            except: pass
        return found_recent

    def get_max_page_from_soup(self, soup):
        try:
            pager = soup.find('div', class_='Pager')
            if not pager: return 1
            pages = [int(a.get_text(strip=True)) for a in pager.find_all('a') if a.get_text(strip=True).isdigit()]
            return max(pages) if pages else 1
        except: return 1

    def fetch_comments(self, thread_data, silent=False):
        self.processed_urls_this_cycle.add(thread_data['link'])
        if thread_data['creator'] == 'Unknown':
             stored = self.threads_collection.find_one({'link': thread_data['link']})
             if stored: thread_data['creator'] = stored.get('creator', 'Unknown')

        try:
            time.sleep(1 if silent else 0.2)
            resp = self.scraper.get(thread_data['link'], timeout=15)
            shield_status = "OK" if resp.status_code == 200 else f"FAIL({resp.status_code})"
            
            if resp.status_code != 200: 
                log(f"   ❌ [Shield:{shield_status}] {thread_data['link']}", RED)
                return False
                
            soup = BeautifulSoup(resp.text, 'html.parser')
            max_page = self.get_max_page_from_soup(soup)
            target_limit = max(1, max_page - 2)
            for page in range(max_page, target_limit - 1, -1):
                p_start = time.time()
                if page == 1 and max_page == 1: content = resp.text
                else:
                    time.sleep(0.2)
                    p_resp = self.scraper.get(f"{thread_data['link']}/p{page}", timeout=15)
                    if p_resp.status_code != 200: continue
                    content = p_resp.text
                has_recent = self.parse_let_comment(content, thread_data)
                if not silent: 
                    author = thread_data.get('creator', 'Unknown')
                    title = thread_data.get('title', 'Unknown')
                    log(f"   📄 [Shield:{shield_status}] {WHITE}@{author}{NC} {CYAN}{title[:30]}...{NC} | P{page}/{max_page} | {time.time()-p_start:.2f}s", GRAY)
                if not has_recent: break
            return True
        except: return False

    def process_rss_item(self, item_str):
        try:
            item_soup = BeautifulSoup(item_str, 'xml')
            title = item_soup.find('title').get_text()
            link = item_soup.find('link').get_text()
            creator = "Unknown"
            c_tag = item_soup.find('dc:creator') or item_soup.find('creator') or item_soup.find('author')
            if c_tag: creator = c_tag.get_text(strip=True)
            pub_date = datetime.strptime(item_soup.find('pubDate').get_text(), "%a, %d %b %Y %H:%M:%S %z")
            
            raw_html = item_soup.find('description').get_text() or ""
            desc_soup = BeautifulSoup(raw_html, 'html.parser')
            
            for a in desc_soup.find_all('a', href=True):
                url = a['href']
                text = a.get_text(strip=True)
                if any(k in text.lower() for k in ['order', 'buy', 'purchase', 'cart', 'here']) or any(k in url.lower() for k in ['cart', 'aff', 'billing', 'whmcs']):
                    a.replace_with(f" {text} (下单链接: {url}) ")
            
            desc_text = desc_soup.get_text(separator=" ", strip=True)

            t_data = {'cate': 'let', 'title': title, 'link': link, 'description': desc_text, 'pub_date': pub_date, 'created_at': datetime.utcnow(), 'creator': creator, 'last_page': 1}
            self.processed_urls_this_cycle.add(link)
            age = (datetime.now(timezone.utc) - pub_date).total_seconds()

            if self.threads_collection.find_one({'link': link}):
                is_processed = self.fetch_comments(t_data, silent=(age > 86400))
                return "SILENT" if (age > 86400 and is_processed) else "ACTIVE"
            else:
                if age <= 86400: self.handle_thread(t_data, []); return "NEW_PUSH"
                else: self.threads_collection.insert_one(t_data); self.fetch_comments(t_data, silent=True); return "OLD_SAVED"
        except: return "ERROR"

    def check_rss(self):
        try:
            start_t = time.time()
            max_w = self.config.get('max_workers', 3) 
            resp = self.scraper.get("https://lowendtalk.com/categories/offers/feed.rss", timeout=30)
            if resp.status_code == 200:
                soup = BeautifulSoup(resp.text, 'xml')
                items = soup.find_all('item')
                log(f"RSS 扫描 | 目标: {len(items)} | 线程: {max_w} | 过盾: ✅ (200)", BLUE, "📡")
                stats = {"SILENT": 0, "ACTIVE": 0, "NEW_PUSH": 0, "ERROR": 0, "OLD_SAVED": 0}
                with ThreadPoolExecutor(max_workers=max_w) as executor:
                    futures = [executor.submit(self.process_rss_item, str(i)) for i in items]
                    for f in as_completed(futures):
                        res = f.result()
                        if res in stats: stats[res] += 1
                log(f"RSS 完成 | 耗时: {time.time()-start_t:.2f}s | 新:{stats['NEW_PUSH']} 活:{stats['ACTIVE']} 静:{stats['SILENT']}", GREEN)
            else:
                log(f"RSS 扫描 | 过盾: ❌ ({resp.status_code})", RED, "📡")
        except Exception as e: log(f"RSS Error: {e}", RED, "❌")

    def check_vip_threads(self):
        vip_urls = self.config.get('vip_threads', [])
        if not vip_urls: return
        log(f"VIP 专线扫描 ({len(vip_urls)})...", MAGENTA, "👑")
        for url in vip_urls:
            try:
                resp = self.scraper.get(url, timeout=30)
                if resp.status_code != 200: continue
                soup = BeautifulSoup(resp.text, 'html.parser')
                title = soup.select_one('.PageTitle h1').get_text(strip=True)
                creator = soup.select_one('.Author .Username').get_text(strip=True) if soup.select_one('.Author .Username') else "Unknown"
                t_data = {'link': url, 'title': title, 'creator': creator, 'pub_date': datetime.now(timezone.utc)}
                self.threads_collection.update_one({'link': url}, {'$setOnInsert': t_data}, upsert=True)
                self.fetch_comments(t_data, silent=False)
            except: pass

    def check_category_list(self):
        target_urls = ["https://lowendtalk.com/categories/offers", "https://lowendtalk.com/categories/announcements"]
        log(f"列表页扫描 ({len(target_urls)})...", MAGENTA, "🔎")
        start_t = time.time()
        for url in target_urls:
            obj_name = url.split('/')[-1]
            try:
                resp = self.scraper.get(url, timeout=30)
                
                shield_state = "✅ 过盾成功" if resp.status_code == 200 else f"❌ 过盾失败 ({resp.status_code})"
                if resp.status_code != 200:
                    log(f"   -> [{obj_name}] {shield_state}", RED)
                    continue
                
                soup = BeautifulSoup(resp.text, 'html.parser')
                candidates = []
                for d in soup.select('.ItemDiscussion') + soup.select('tr.ItemDiscussion'):
                    try:
                        a = d.select_one('.DiscussionName a') or d.find('h3', class_='DiscussionName').find('a')
                        if not a: continue
                        link = a['href']
                        if not link.startswith('http'): link = "https://lowendtalk.com" + link
                        if link in self.processed_urls_this_cycle: continue
                        
                        dt = d.select_one('.LastCommentDate time') or d.select_one('.DateUpdated time')
                        if dt and dt.has_attr('datetime'):
                            last_active = datetime.strptime(dt['datetime'], "%Y-%m-%dT%H:%M:%S%z")
                            if (datetime.now(timezone.utc) - last_active).total_seconds() < 172800:
                                creator = d.select_one('.FirstUser').get_text(strip=True) if d.select_one('.FirstUser') else "Unknown"
                                candidates.append({'link': link, 'title': a.get_text(strip=True), 'creator': creator})
                    except: continue
                
                result_msg = f"发现 {len(candidates)} 新候选项" if candidates else "无新候选项 (RSS已覆盖)"
                color = YELLOW if candidates else GRAY
                log(f"   -> [{obj_name}] {shield_state} | 结果: {result_msg}", color)

                for t in candidates: self.fetch_comments(t, silent=False)
            except Exception as e:
                log(f"   -> [{obj_name}] 错误: {e}", RED)
        log(f"列表页完成 | 耗时: {time.time()-start_t:.2f}s", MAGENTA)

    def start_monitoring(self):
        log("=== 监控服务启动 (v79) ===", GREEN, "🚀")
        freq = self.config.get('frequency', 300)
        while True:
            t0 = time.time()
            self.processed_urls_this_cycle.clear()
            print(f"{GRAY}--------------------------------------------------{NC}")
            self.check_rss()
            self.check_vip_threads()
            self.check_category_list()
            self.update_heartbeat()
            log(f"⏱️ 耗时: {time.time()-t0:.2f}s | 休眠 {freq}s...", YELLOW)
            time.sleep(freq)

if __name__ == "__main__":
    sys.stdout.reconfigure(line_buffering=True)
    ForumMonitor().start_monitoring()
EOF

    # 更新依赖
    cat <<EOF > "$APP_DIR/requirements.txt"
requests
beautifulsoup4
pymongo
urllib3<2.0
lxml
google-generativeai
cloudscraper
psutil
EOF

    msg_info "写入推送模块 (Pushplus + Telegram Beautify + Failover)..."
    cat <<'EOF' > "$APP_DIR/send.py"
import json
import requests
import os
import re
import html
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from datetime import datetime

GREEN = '\033[0;32m'
RED = '\033[0;31m'
YELLOW = '\033[0;33m'
NC = '\033[0m'
GRAY = '\033[0;90m'

def log(msg, color=NC, icon=""):
    timestamp = datetime.now().strftime("%H:%M:%S")
    prefix = f"{icon} " if icon else ""
    print(f"{GRAY}[{timestamp}]{NC} {color}{prefix}{msg}{NC}")

class NotificationSender:
    def __init__(self, config_path='data/config.json'):
        self.config_path = config_path
        base_dir = os.path.dirname(os.path.abspath(config_path))
        self.stats_path = os.path.join(base_dir, 'stats.json')
        self.pushplus_token = ""
        self.tg_bot_token = ""
        self.tg_chat_id = ""
        self.enable_pushplus = True
        self.enable_telegram = True
        
        self.session = requests.Session()
        self.session.headers.update({'User-Agent': 'curl/7.74.0'})
        adapter = HTTPAdapter(max_retries=Retry(total=3, backoff_factor=1))
        self.session.mount("https://", adapter)
        self.load_config()

    def load_config(self):
        try:
            with open(self.config_path, 'r') as f:
                cfg = json.load(f)['config']
                self.pushplus_token = cfg.get('pushplus_token', '')
                self.tg_bot_token = cfg.get('telegram_bot_token', '')
                self.tg_chat_id = cfg.get('telegram_chat_id', '')
                self.enable_pushplus = cfg.get('enable_pushplus', True)
                self.enable_telegram = cfg.get('enable_telegram', True)
        except: pass

    def record_success(self):
        try:
            stats = {}
            if os.path.exists(self.stats_path):
                with open(self.stats_path, 'r') as f: stats = json.load(f)
            stats['push_count'] = stats.get('push_count', 0) + 1
            with open(self.stats_path, 'w') as f: json.dump(stats, f)
        except Exception as e: log(f"Stats Error: {e}", RED, "❌")

    def send_message(self, message):
        return self.send_html_message("ForumMonitor Notification", message)

    def send_telegram(self, title, html_content):
        if not self.enable_telegram: return False
        if not self.tg_bot_token or not self.tg_chat_id: return False
        try:
            # 1. Clean up HTML for Telegram
            msg = html_content 
            msg = msg.replace("<br>", "\n").replace("<br/>", "\n")
            msg = re.sub(r'<div.*?>', '', msg).replace('</div>', '\n')
            msg = re.sub(r'<span.*?>', '', msg).replace('</span>', ' ')
            while "\n\n\n" in msg: msg = msg.replace("\n\n\n", "\n\n")
            
            messages = []
            # Updated Max Length to Telegram API limit (4096)
            MAX_LEN = 4095
            if len(msg) > MAX_LEN:
                while len(msg) > 0:
                    if len(msg) <= MAX_LEN: messages.append(msg); break
                    split_idx = msg.rfind('\n', 0, MAX_LEN)
                    if split_idx == -1: split_idx = MAX_LEN
                    messages.append(msg[:split_idx])
                    msg = msg[split_idx:]
            else: messages.append(msg)

            all_success = True
            for i, part in enumerate(messages):
                url = f"https://api.telegram.org/bot{self.tg_bot_token}/sendMessage"
                
                # Try sending as HTML first
                payload = {'chat_id': self.tg_chat_id, 'text': part, 'parse_mode': 'HTML', 'disable_web_page_preview': True}
                resp = self.session.post(url, json=payload, timeout=15)
                
                if resp.status_code == 200: 
                    log(f"Telegram Success: {title[:25]}...", GREEN, "✈️")
                else:
                    # --- Failover: Try sending as Plain Text if HTML fails ---
                    if resp.status_code == 400:
                        log(f"⚠️ TG HTML Error ({resp.status_code}). Retrying as Plain Text...", YELLOW)
                        # Strip all tags and UNESCAPE HTML entities (e.g. &lt; -> <)
                        clean_text = re.sub(r'<[^>]+>', '', part)
                        clean_text = html.unescape(clean_text)
                        
                        payload_retry = {'chat_id': self.tg_chat_id, 'text': clean_text, 'disable_web_page_preview': True}
                        retry_resp = self.session.post(url, json=payload_retry, timeout=15)
                        
                        if retry_resp.status_code == 200:
                             log(f"Telegram Text Retry Success: {title[:25]}...", GREEN, "✈️")
                             continue
                        else:
                             log(f"Retry Failed: {retry_resp.text}", RED)
                    # -------------------------------------------------------
                    
                    log(f"Telegram Failed ({resp.status_code}): {resp.text}", RED, "❌"); all_success = False
            return all_success
        except Exception as e: log(f"Telegram Error: {e}", RED, "❌"); return False

    def send_html_message(self, title, html_content):
        success_count = 0
        
        # Pushplus
        if self.enable_pushplus and self.pushplus_token and self.pushplus_token != "YOUR_PUSHPLUS_TOKEN_HERE":
            try:
                pp_title = title[:90] + "..." if len(title) > 95 else title
                payload = {"token": self.pushplus_token, "title": pp_title, "content": html_content, "template": "html"}
                resp = self.session.post("https://www.pushplus.plus/send", json=payload, timeout=15)
                if resp.status_code == 200 and resp.json().get('code') == 200:
                    log(f"Pushplus Success: {title[:25]}...", GREEN, "📨"); success_count += 1
                else: 
                    reason = resp.text
                    level = RED
                    if "用户账号使用受限" in reason: level = YELLOW
                    log(f"Pushplus Failed ({resp.status_code}): {reason}", level, "❌")
            except Exception as e: log(f"Pushplus Error: {e}", RED, "❌")

        # Telegram
        if self.send_telegram(title, html_content): success_count += 1
        
        if success_count > 0: self.record_success(); return True
        return False
EOF
}

# --- 部署流程 ---

run_apply_app_update() {
    check_service_exists 
    _write_python_files_and_deps
    run_update_config_prompt
    msg_info "更新 Python 依赖..."
    "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt" > /dev/null
    run_restart
    msg_ok "更新完成"
}

run_install() {
    msg_info "=== 开始部署 ForumMonitor (v79: StableFix) ==="
    
    # 1. 安装系统依赖
    msg_info "更新系统与依赖 (apt-get)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq python3 python3-pip python3-venv nodejs jq curl gnupg lsb-release

    # 2. 安装 MongoDB (仅当未安装时)
    if ! command -v mongod &> /dev/null; then
        msg_info "安装 MongoDB..."
        local C=$(lsb_release -cs)
        local G="/usr/share/keyrings/mongodb-server.gpg"
        
        if [ "$C" == "bookworm" ]; then
            curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | gpg --dearmor -o $G
            echo "deb [ arch=amd64,arm64 signed-by=$G ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/7.0 main" | tee /etc/apt/sources.list.d/mongodb-org.list
        else
            curl -fsSL https://www.mongodb.org/static/pgp/server-6.0.asc | gpg --dearmor -o $G
            echo "deb [ arch=amd64,arm64 signed-by=$G ] https://repo.mongodb.org/apt/debian bullseye/mongodb-org/6.0 main" | tee /etc/apt/sources.list.d/mongodb-org.list
        fi
        apt-get update -qq && apt-get install -y -qq mongodb-org
    else
        msg_ok "MongoDB 已安装，跳过"
    fi

    systemctl start mongod && systemctl enable mongod

    # 3. 部署应用文件
    mkdir -p "$APP_DIR/data"
    _write_python_files_and_deps
    
    # 4. 创建虚拟环境 (仅当不存在时)
    if [ ! -d "$VENV_DIR" ]; then 
        msg_info "创建 Python venv..."
        python3 -m venv "$VENV_DIR"
    fi
    
    msg_info "安装 Python 依赖..."
    "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt" > /dev/null

    # 5. 生成配置文件
    if [ ! -f "$CONFIG_FILE" ]; then
        read -p "Pushplus Token: " PT
        read -p "Telegram Bot Token: " TG_TOK
        read -p "Telegram Chat ID: " TG_ID
        read -p "Gemini API Key: " GK
        # New Prompt for First Install (Strict Format, CLEANED)
        local PROMPT="你是一个中文VPS助手。请分析此促销信息。
目标：提取所有套餐信息。
规则：
1. 不要使用 Markdown 代码块。
2. 不要使用 HTML 标签。
3. 必须严格按照以下格式输出：

[促销] <商家名称>
配置：<CPU> <内存> <硬盘> <带宽/流量>
价格：<价格>
链接：<购买链接1>
链接：<购买链接2> (如果有多个链接，请换行重复“链接：”前缀)
优惠码：<优惠码> (没有则不写)
总结：<简短摘要>

(如果有多个套餐，请空一行后重复上述格式)"
        
        local FILTER="你是一个VPS优惠分析师。请分析回复。
规则：
1. 忽略订单号/晒单/求翻倍。
2. 忽略无关闲聊。
3. 仅提取新优惠。

**格式要求（纯文本，不要Markdown）**：

[促销] <商家名称>
配置：<核心> <内存> <硬盘> <带宽>
价格：<价格>
链接：<链接> (多个链接请换行)
优惠码：<优惠码> (可选)
总结：<简短摘要>"

        # 移除 \r 保证 JSON 安全
        PROMPT="${PROMPT//\r/}"
        FILTER="${FILTER//\r/}"
        
        jq -n --arg pt "$PT" --arg gk "$GK" --arg prompt "$PROMPT" --arg tt "$TG_TOK" --arg ti "$TG_ID" --arg filter "$FILTER" \
           '{config: {pushplus_token: $pt, telegram_bot_token: $tt, telegram_chat_id: $ti, gemini_api_key: $gk, model: "gemini-2.0-flash-lite", ai_provider: "gemini", cf_account_id: "", cf_api_token: "", cf_model: "@cf/meta/llama-3.1-8b-instruct", thread_prompt: $prompt, filter_prompt: $filter, frequency: 300, vip_threads: [], monitored_roles: ["creator","provider","top_host","host_rep","admin"], monitored_usernames: [], enable_pushplus: true, enable_telegram: true}}' > "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
    else
        run_update_config_prompt
    fi

    # 6. 配置 Systemd
    cat <<EOF > "$SYSTEMD_SERVICE_FILE"
[Unit]
Description=Forum Monitor Service
After=network.target mongod.service
Requires=mongod.service
StartLimitInterval=0
StartLimitBurst=0

[Service]
Environment="PROXY_HOST="
Environment="MONGO_HOST=mongodb://localhost:27017/"
Environment="PYTHONUNBUFFERED=1"
Environment="PYTHONIOENCODING=utf-8"
Environment="TERM=xterm-256color"
User=root
WorkingDirectory=$APP_DIR
ExecStart=$VENV_DIR/bin/python $APP_DIR/$PYTHON_SCRIPT_NAME
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME.service"
    systemctl start "$SERVICE_NAME.service"
    ln -s -f "$(realpath "$0")" "$SHORTCUT_PATH"
    
    msg_ok "安装完成! 重新加载中..."
    sleep 2
    exec "$0"
}

# --- 菜单逻辑 ---

show_menu() {
    clear
    show_dashboard
    echo -e "${GREEN} 选项菜单 ${NC}"
    echo -e "${GRAY}----------------------------------------------------------------${NC}"
    
    echo -e "${CYAN} [基础管理]${NC}"
    printf "  %-4s %-12s %b%s%b\n" "1." "install" "$GRAY" "安装/重置" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "2." "uninstall" "$GRAY" "彻底卸载" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "3." "update" "$GRAY" "更新代码(补丁)" "$NC"
    
    echo -e "${CYAN} [服务控制]${NC}"
    printf "  %-4s %-12s %b%s%b\n" "4." "start" "$GRAY" "启动" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "5." "stop" "$GRAY" "停止" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "6." "restart" "$GRAY" "重启" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "7." "status" "$GRAY" "状态" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "8." "logs" "$GRAY" "日志" "$NC"

    echo -e "${CYAN} [配置管理]${NC}"
    printf "  %-4s %-12s %b%s%b\n" "9." "edit" "$GRAY" "修改Token/ID" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "10." "ai-switch" "$GRAY" "切换AI引擎" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "11." "frequency" "$GRAY" "调整频率" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "12." "threads" "$GRAY" "修改线程数" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "13." "keepalive" "$GRAY" "开启保活" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "14." "toggle-push" "$GREEN" "推送通道开关" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "15." "prompt" "$GRAY" "AI提示词设置" "$NC"

    echo -e "${CYAN} [监控规则]${NC}"
    printf "  %-4s %-12s %b%s%b\n" "16." "vip" "$GRAY" "VIP专线" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "17." "roles" "$GRAY" "监控角色" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "18." "users" "$GRAY" "指定用户" "$NC"

    echo -e "${CYAN} [功能测试]${NC}"
    printf "  %-4s %-12s %b%s%b\n" "19." "test-ai" "$GRAY" "测试 AI" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "20." "test-push" "$GRAY" "测试推送" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "21." "history" "$GRAY" "推送历史" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "22." "repush" "$GRAY" "手动重推" "$NC"

    echo -e "${GRAY}----------------------------------------------------------------${NC}"
    echo -e "  q. quit         退出"
}

main() {
    kill_zombie_loggers
    if [ "${1:-}" == "--post-update" ]; then 
        run_apply_app_update
        read -n 1 -s -r -p "按任意键继续..."
    elif [ -n "${1:-}" ]; then
        case "$1" in
            install|1) run_install ;;
            uninstall|2) run_uninstall ;;
            start|4) run_start ;;
            stop|5) run_stop ;;
            restart|6) run_restart ;;
            status|7) run_status ;;
            logs|8) run_logs ;;
            edit|9) run_edit_config ;;
            ai-switch|10) run_ai_switch ;;
            frequency|11) run_edit_frequency ;;
            threads|12) run_edit_threads ;;
            keepalive|13) run_setup_keepalive ;;
            toggle-push|14) run_toggle_push ;;
            prompt|15) run_manage_prompts ;;
            vip|16) run_manage_vip ;;
            roles|17) run_manage_roles ;;
            users|18) run_manage_users ;;
            test-ai|19) run_test_ai ;;
            test-push|20) run_test_push ;;
            history|21) run_view_history; read -n 1 -s -r -p "..." ;;
            repush|22) run_repush_active; read -n 1 -s -r -p "..." ;;
            update|3) run_apply_app_update; read -n 1 -s -r -p "..." ;; 
            monitor) run_monitor_logic ;;
            *) show_menu; exit 1 ;;
        esac; exit 0
    fi

    while true; do
        show_menu
        echo -e -n "${YELLOW}请输入选项: ${NC}"
        read CMD
        case "$CMD" in
            1) run_install; read -n 1 -s -r -p "..." ;;
            2) run_uninstall; exit 0 ;;
            3) run_apply_app_update; read -n 1 -s -r -p "..." ;;
            4) run_start; read -n 1 -s -r -p "..." ;;
            5) run_stop; read -n 1 -s -r -p "..." ;;
            6) run_restart; read -n 1 -s -r -p "..." ;;
            7) run_status; read -n 1 -s -r -p "..." ;;
            8) run_logs ;;
            9) run_edit_config; read -n 1 -s -r -p "..." ;;
            10) run_ai_switch ;;
            11) run_edit_frequency; read -n 1 -s -r -p "..." ;;
            12) run_edit_threads; read -n 1 -s -r -p "..." ;;
            13) run_setup_keepalive; read -n 1 -s -r -p "..." ;;
            14) run_toggle_push ;;
            15) run_manage_prompts ;;
            16) run_manage_vip ;;
            17) run_manage_roles ;;
            18) run_manage_users ;;
            19) run_test_ai; read -n 1 -s -r -p "..." ;;
            20) run_test_push; read -n 1 -s -r -p "..." ;;
            21) run_view_history; read -n 1 -s -r -p "..." ;;
            22) run_repush_active; read -n 1 -s -r -p "..." ;;
            q|Q|0) break ;;
            *) ;;
        esac
    done
}

main "$@"
