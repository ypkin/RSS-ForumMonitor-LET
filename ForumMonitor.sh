#!/bin/bash

# --- ForumMonitor 管理脚本 (v55.3: Mixed Format) ---
# Version: 2025.11.30.55.3
# Changes:
# [x] Restore: Kept metadata headers (Avatar, Time, Model, Thread-Starter/Interruption).
# [x] Format: Body content strictly follows the Clean Key-Value format (Config/Price/Link).
#
# --- (c) 2025 ---

set -e
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
        msg_err "服务 $SERVICE_NAME 未安装。请先运行 'install'。"
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
    [ -f "$STATS_FILE" ] && PUSH_COUNT=$(jq -r '.push_count // 0' "$STATS_FILE")
    
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
        CUR_PROVIDER=$(jq -r '.config.ai_provider // "gemini"' "$CONFIG_FILE")
        if [ "$CUR_PROVIDER" == "workers" ]; then
             CUR_MODEL=$(jq -r '.config.cf_model // "llama-3.1-8b"' "$CONFIG_FILE")
        else
             CUR_MODEL=$(jq -r '.config.model // "gemini-2.0-flash-lite"' "$CONFIG_FILE")
        fi
        CUR_FREQ=$(jq -r '.config.frequency // 300' "$CONFIG_FILE")
        
        local RAW_PP=$(jq -r '.config.enable_pushplus' "$CONFIG_FILE" | xargs)
        local RAW_TG=$(jq -r '.config.enable_telegram' "$CONFIG_FILE" | xargs)
        
        if [ "$RAW_PP" == "false" ]; then S_PP="OFF"; C_PP="GRAY"; fi
        if [ "$RAW_TG" == "false" ]; then S_TG="OFF"; C_TG="GRAY"; fi
    fi

    echo -e "${BLUE}================================================================${NC}"
    echo -e " ${CYAN}ForumMonitor (v55.3: Mixed Format)${NC}"
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

        local PP_ST=$(jq -r '.config.enable_pushplus' "$CONFIG_FILE" | xargs)
        local TG_ST=$(jq -r '.config.enable_telegram' "$CONFIG_FILE" | xargs)
        [ "$PP_ST" == "null" ] && PP_ST="true"
        [ "$TG_ST" == "null" ] && TG_ST="true"
        
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
    jq 'if .config.monitored_roles == null then .config.monitored_roles = ["creator","provider","top_host","host_rep","admin"] else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

    while true; do
        echo -e "\n${CYAN}--- 监控角色设置 ---${NC}"
        has_role() { jq -e --arg r "$1" '.config.monitored_roles | index($r)' "$CONFIG_FILE" >/dev/null; }
        
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
    read -p "Telegram Chat/Channel ID (频道需带 -100 前缀): " N_TG_ID
    
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
        local DIFF=$(($(date +%s) - $(cat "$HEARTBEAT_FILE")))
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
    
    # 捕获 SIGINT (Ctrl+C): 清理并直接退出脚本，回到Shell (不停止服务)
    trap 'trap - EXIT; cleanup; echo -e "\n${GREEN}[Exit] 已退出脚本 (回到Shell)${NC}"; exit 0' SIGINT
    # 捕获 EXIT: 确保异常退出时也清理日志进程
    trap cleanup EXIT

    # 循环检测按键 '0'
    while true; do
        read -n 1 -s -r key
        if [[ "$key" == "0" ]]; then
            break
        fi
    done
    
    cleanup
    # 复原Trap
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
        html_summary = html_summary.replace('[ORDER_LINK_HERE]', '')
        
        pub_date = t['pub_date']
        if pub_date.tzinfo is None: pub_date = pub_date.replace(tzinfo=timezone.utc)
        time_str = pub_date.astimezone(SHANGHAI).strftime('%Y-%m-%d %H:%M')
        
        safe_title = t['title'].replace('<', '&lt;').replace('>', '&gt;')
        safe_creator = t.get('creator', 'Unknown').replace('<', '&lt;').replace('>', '&gt;')
        model_n = m.config.get('model') if m.ai_provider == 'gemini' else m.config.get('cf_model')

        msg_content = (
            f'<b>🟡 [Repush] {safe_title}</b><br>'
            f'👤 {safe_creator} | 🕒 {time_str} | 🤖 {model_n}<br>'
            f'{\"-\"*20}<br>'
            f'{html_summary}<br>'
            f'{\"-\"*20}<br>'
            f'<a href=\"{t[\"link\"]}\">👉 查看原帖 (Source)</a>'
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
    f'<b>🟢 [TEST] 模拟 VPS 优惠通知</b><br>'
    f'👤 TestUser | 🕒 {time_str} | 🤖 Mock-Model-v1<br>'
    f'{\"-\"*20}<br>'
    f'<b>🏆 AI 甄选 (高性价比)：</b><br>'
    f'• <b>2GB KVM VPS</b> (\$10.00/yr): 价格极低，适合跑测试。<br><br>'
    f'<b>VPS 列表：</b><br>'
    f'• <b>4GB RAM Plan</b> → \$20.00/yr <a href=\"https://google.com\">[下单地址]</a><br>'
    f'   └ 2 Core / 4GB / 50GB NVMe / 1Gbps<br><br>'
    f'<b>🎁 内容:</b> 模拟的优惠内容描述...<br>'
    f'<b>🏷️ 代码/规则:</b> TEST-CODE-2025<br>'
    f'{\"-\"*20}<br>'
    f'<a href=\"https://google.com\">👉 查看原帖 (Source)</a>'
)

s.send_html_message(title, content)
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
    local LAST=$(cat "$HEARTBEAT_FILE")
    local FREQ=$(jq -r '.config.frequency // 600' "$CONFIG_FILE")
    local DIFF=$(($(date +%s) - LAST))
    if [ "$DIFF" -gt "$(($FREQ + 300))" ]; then
        echo "$(date): [Watchdog] 服务僵死重启" >> "$RESTART_LOG_FILE"
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

# --- Prompt 保持上一版的清爽格式 ---
run_update_config_prompt() {
    if [ -f "$CONFIG_FILE" ]; then
        jq 'if .config.vip_threads == null then .config.vip_threads = [] else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        jq 'if .config.monitored_usernames == null then .config.monitored_usernames = [] else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        jq 'if .config.monitored_roles == null then .config.monitored_roles = ["creator","provider","top_host","host_rep","administrator"] else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        
        # New Toggles (Default True)
        jq 'if .config.enable_pushplus == null then .config.enable_pushplus = true else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        jq 'if .config.enable_telegram == null then .config.enable_telegram = true else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

        jq 'if .config.ai_provider == null then .config.ai_provider = "gemini" else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        jq 'if .config.cf_model == null then .config.cf_model = "@cf/meta/llama-3.1-8b-instruct" else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

        local NEW_THREAD_PROMPT="你是一个中文智能助手。请分析这条 VPS 优惠信息，**必须将所有内容（包括机房、配置）翻译为中文**。请筛选出 1-2 个性价比最高的套餐，并严格按照以下格式输出（不要代码块）：\n\n🏆 **AI 甄选 (高性价比)**：\n• **<套餐名>** (<价格>)：<简短推荐理由>\n\nVPS 列表：\n• **<套餐名>** → <价格> [ORDER_LINK_HERE]\n   └ <核心> / <内存> / <硬盘> / <带宽> / <流量>\n(注意：请在**每一个**识别到的套餐价格后面都加上 [ORDER_LINK_HERE] 占位符。)\n\n限时福利：\n• <优惠码/折扣/活动截止时间>\n\n基础设施：\n• <机房位置> | <IP类型> | <网络特点>\n\n支付方式：\n• <支付手段>\n\n🟢 优点: <简短概括>\n🔴 缺点: <简短概括>\n🎯 适合: <适用人群>"
        # UPDATED FILTER PROMPT FOR CLEAN FORMAT (Config/Price/Link)
        local NEW_FILTER_PROMPT="你是一个VPS社区福利分析师。请分析这条回复。只有当内容包含：**补货/降价/新优惠码** (Sales) 或 **抽奖/赠送/免费试用/送余额** (Giveaways/Perks) 等实质性利好时，才提取信息。否则回复 FALSE。如果符合，请务必严格按以下格式提取（不要Markdown代码块）：\n\n[促销] <商家名>\n配置：<核心 内存 硬盘 带宽 (若有)>\n价格：<价格 (若有)>\n链接：<直达链接>\n优惠码：<优惠码 (若无则填无)>\n总结：<一句话简短摘要>"

        jq -n --arg pt "$PT" --arg gk "$GK" --arg prompt "$PROMPT" --arg fprompt "$NEW_FILTER_PROMPT" --arg tt "$TG_TOK" --arg ti "$TG_ID" \
           '{config: {pushplus_token: $pt, telegram_bot_token: $tt, telegram_chat_id: $ti, gemini_api_key: $gk, model: "gemini-2.0-flash-lite", ai_provider: "gemini", cf_account_id: "", cf_api_token: "", cf_model: "@cf/meta/llama-3.1-8b-instruct", thread_prompt: $prompt, filter_prompt: $fprompt, frequency: 300, vip_threads: [], monitored_roles: ["creator","provider","top_host","host_rep","admin"], monitored_usernames: [], enable_pushplus: true, enable_telegram: true}}' > "$CONFIG_FILE"
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

    echo -e "${CYAN} [监控规则]${NC}"
    printf "  %-4s %-12s %b%s%b\n" "15." "vip" "$GRAY" "VIP专线" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "16." "roles" "$GRAY" "监控角色" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "17." "users" "$GRAY" "指定用户" "$NC"

    echo -e "${CYAN} [功能测试]${NC}"
    printf "  %-4s %-12s %b%s%b\n" "18." "test-ai" "$GRAY" "测试 AI" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "19." "test-push" "$GRAY" "测试推送" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "20." "history" "$GRAY" "推送历史" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "21." "repush" "$GRAY" "手动重推" "$NC"

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
            vip|15) run_manage_vip ;;
            roles|16) run_manage_roles ;;
            users|17) run_manage_users ;;
            test-ai|18) run_test_ai ;;
            test-push|19) run_test_push ;;
            history|20) run_view_history; read -n 1 -s -r -p "..." ;;
            repush|21) run_repush_active; read -n 1 -s -r -p "..." ;;
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
            15) run_manage_vip ;;
            16) run_manage_roles ;;
            17) run_manage_users ;;
            18) run_test_ai; read -n 1 -s -r -p "..." ;;
            19) run_test_push; read -n 1 -s -r -p "..." ;;
            20) run_view_history; read -n 1 -s -r -p "..." ;;
            21) run_repush_active; read -n 1 -s -r -p "..." ;;
            q|Q|0) break ;;
            *) ;;
        esac
    done
}

main "$@"
