#!/bin/bash

# --- ForumMonitor 管理脚本 (v34: Menu Reordered) ---
# Version: 2025.11.29.34
# Features: 
# [x] Menu Reordered: Sequential 1-20
# [x] Fix: Telegram Error 400 (Escape special chars in Titles/Usernames)
# [x] Dual AI Support: Google Gemini / Cloudflare Workers AI
# [x] Shared Prompt System
# [x] Fix: Strip Blockquotes (防止引用内容重复)
# [x] API Fix: Enhanced Rate Limit Handler
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
    
    if [ -f "$CONFIG_FILE" ]; then
        CUR_PROVIDER=$(jq -r '.config.ai_provider // "gemini"' "$CONFIG_FILE")
        if [ "$CUR_PROVIDER" == "workers" ]; then
             CUR_MODEL=$(jq -r '.config.cf_model // "llama-3.1-8b"' "$CONFIG_FILE")
        else
             CUR_MODEL=$(jq -r '.config.model // "gemini-2.0-flash-lite"' "$CONFIG_FILE")
        fi
        CUR_FREQ=$(jq -r '.config.frequency // 300' "$CONFIG_FILE")
    fi

    echo -e "${BLUE}================================================================${NC}"
    echo -e " ${CYAN}ForumMonitor (v34: Menu Reordered)${NC}"
    echo -e "${BLUE}================================================================${NC}"
    printf " %-16s %b%-20s%b | %-16s %b%-10s%b\n" "运行状态:" "$STATUS_COLOR" "$STATUS_TEXT" "$NC" "已推送通知:" "$GREEN" "$PUSH_COUNT" "$NC"
    printf " %-16s %b%-20s%b | %-16s %b%-10s%b\n" "AI 引擎:" "$CYAN" "${CUR_PROVIDER^^}" "$NC" "轮询间隔:" "$CYAN" "${CUR_FREQ}s" "$NC"
    printf " %-16s %b%-20s%b | %-16s %b%-10s%b\n" "当前模型:" "$CYAN" "${CUR_MODEL:0:18}.." "$NC" "自动重启:" "$RED" "$RESTART_COUNT 次" "$NC"
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
    msg_ok "服务已停止"
}

run_restart() {
    check_service_exists
    msg_info "正在重启服务..."
    systemctl restart $SERVICE_NAME
    msg_ok "服务已重启"
}

run_manage_vip() {
    check_service_exists
    check_jq
    
    while true; do
        echo -e "\n${CYAN}--- VIP 专线监控管理 ---${NC}"
        echo -e "${GRAY}VIP 列表中的帖子将强制每轮扫描，无视时间和板块限制。${NC}"
        
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
        
        echo -e "\n${YELLOW}操作选项:${NC}"
        echo "  1. 添加 URL (Add)"
        echo "  2. 删除 URL (Del)"
        echo "  3. 返回上级 (Back)"
        read -p "请选择: " OPT
        
        case "$OPT" in
            1)
                read -p "请输入帖子完整 URL: " NEW_URL
                if [[ "$NEW_URL" == http* ]]; then
                    jq 'if .config.vip_threads == null then .config.vip_threads = [] else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                    
                    if jq -e --arg url "$NEW_URL" '.config.vip_threads | index($url)' "$CONFIG_FILE" >/dev/null; then
                        msg_warn "该 URL 已存在!"
                    else
                        jq --arg url "$NEW_URL" '.config.vip_threads += [$url]' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                        msg_ok "添加成功"
                    fi
                else
                    msg_err "无效的 URL"
                fi
                ;;
            2)
                read -p "请输入要删除的序号 (0-$((COUNT-1))): " DEL_IDX
                if [[ "$DEL_IDX" =~ ^[0-9]+$ ]] && [ "$DEL_IDX" -lt "$COUNT" ]; then
                    jq "del(.config.vip_threads[$DEL_IDX])" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                    msg_ok "删除成功"
                else
                    msg_err "无效序号"
                fi
                ;;
            3) return ;;
            *) ;;
        esac
    done
}

run_manage_users() {
    check_service_exists
    check_jq
    
    while true; do
        echo -e "\n${CYAN}--- 指定用户监控 (Target Users) ---${NC}"
        echo -e "${GRAY}在此列表中的用户，无论是否有商家身份，都会被强制监控。${NC}"
        
        local USERS=$(jq -r '.config.monitored_usernames[]' "$CONFIG_FILE" 2>/dev/null || echo "")
        local COUNT=0
        if [ -n "$USERS" ]; then
            echo -e "\n当前指定用户列表:"
            IFS=$'\n'
            for u in $USERS; do
                echo -e "  [${GREEN}$COUNT${NC}] $u"
                COUNT=$((COUNT+1))
            done
            unset IFS
        else
            echo -e "\n(列表为空)"
        fi
        
        echo -e "\n${YELLOW}操作选项:${NC}"
        echo "  1. 添加用户名 (Add)"
        echo "  2. 删除用户名 (Del)"
        echo "  3. 返回上级 (Back)"
        read -p "请选择: " OPT
        
        case "$OPT" in
            1)
                read -p "请输入用户名 (区分大小写, 例如 Spirit): " NEW_USER
                if [ -n "$NEW_USER" ]; then
                    jq 'if .config.monitored_usernames == null then .config.monitored_usernames = [] else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                    
                    if jq -e --arg u "$NEW_USER" '.config.monitored_usernames | index($u)' "$CONFIG_FILE" >/dev/null; then
                        msg_warn "该用户已存在!"
                    else
                        jq --arg u "$NEW_USER" '.config.monitored_usernames += [$u]' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                        msg_ok "添加成功"
                    fi
                else
                    msg_err "用户名不能为空"
                fi
                ;;
            2)
                read -p "请输入要删除的序号 (0-$((COUNT-1))): " DEL_IDX
                if [[ "$DEL_IDX" =~ ^[0-9]+$ ]] && [ "$DEL_IDX" -lt "$COUNT" ]; then
                    jq "del(.config.monitored_usernames[$DEL_IDX])" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                    msg_ok "删除成功"
                else
                    msg_err "无效序号"
                fi
                ;;
            3) return ;;
            *) ;;
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
        
        echo -e "\n${YELLOW}操作选项 (1-6 切换, q 返回):${NC}"
        read -p "请选择: " OPT
        target=""
        case "$OPT" in
            1) target="creator" ;; 2) target="provider" ;; 3) target="top_host" ;;
            4) target="host_rep" ;; 5) target="admin" ;; 6) target="other" ;;
            q|Q) return ;; *) continue ;;
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

    echo -e "\n${CYAN}--- AI 引擎切换 (AI Switch) ---${NC}"
    echo -e "当前使用: ${GREEN}${CUR_PROVIDER^^}${NC}"
    echo -e "${GRAY}注意: 两种 AI 共享同一套提示词 (Prompt)，无需单独修改。${NC}\n"

    echo "  1. 使用 Google Gemini (推荐)"
    echo "  2. 使用 Cloudflare Workers AI"
    echo "  3. 返回"
    read -p "请选择 AI 提供商: " SEL
    
    case "$SEL" in
        1)
            echo -e "\n${BLUE}--- 配置 Gemini ---${NC}"
            read -p "API Key (当前: ***${CUR_G_KEY: -6}): " N_KEY
            read -p "Model (当前: $CUR_G_MODEL): " N_MODEL
            
            [ -z "$N_KEY" ] && N_KEY="$CUR_G_KEY"
            [ -z "$N_MODEL" ] && N_MODEL="$CUR_G_MODEL"
            
            jq --arg k "$N_KEY" --arg m "$N_MODEL" \
               '.config.ai_provider="gemini" | .config.gemini_api_key=$k | .config.model=$m' \
               "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
            msg_ok "已切换至 Gemini，正在重启服务..."
            run_restart
            ;;
        2)
            echo -e "\n${BLUE}--- 配置 Workers AI ---${NC}"
            echo -e "${GRAY}需要 Cloudflare Account ID 和 API Token (需有 Workers AI 权限)${NC}"
            read -p "Account ID (当前: $CUR_CF_ACC): " N_ACC
            read -p "API Token (当前: ***${CUR_CF_TOK: -6}): " N_TOK
            read -p "Model (当前: $CUR_CF_MODEL): " N_MODEL
            
            [ -z "$N_ACC" ] && N_ACC="$CUR_CF_ACC"
            [ -z "$N_TOK" ] && N_TOK="$CUR_CF_TOK"
            [ -z "$N_MODEL" ] && N_MODEL="$CUR_CF_MODEL"
            
            jq --arg a "$N_ACC" --arg t "$N_TOK" --arg m "$N_MODEL" \
               '.config.ai_provider="workers" | .config.cf_account_id=$a | .config.cf_api_token=$t | .config.cf_model=$m' \
               "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
            msg_ok "已切换至 Workers AI，正在重启服务..."
            run_restart
            ;;
        *) return ;;
    esac
}

run_edit_config() {
    check_service_exists
    check_jq
    echo "--- 修改基础配置 (直接回车保留原值) ---"
    
    local C_PT=$(jq -r '.config.pushplus_token' "$CONFIG_FILE")
    local C_TG_TOK=$(jq -r '.config.telegram_bot_token // ""' "$CONFIG_FILE")
    local C_TG_ID=$(jq -r '.config.telegram_chat_id // ""' "$CONFIG_FILE")

    read -p "Pushplus Token (当前: ${C_PT: -6}): " N_PT
    echo -e "${YELLOW}Telegram 配置 (留空则不启用)${NC}"
    read -p "Telegram Bot Token (当前: ${C_TG_TOK:0:9}...): " N_TG_TOK
    read -p "Telegram Chat ID (当前: $C_TG_ID): " N_TG_ID
    
    [ -z "$N_PT" ] && N_PT="$C_PT"
    [ -z "$N_TG_TOK" ] && N_TG_TOK="$C_TG_TOK"
    [ -z "$N_TG_ID" ] && N_TG_ID="$C_TG_ID"

    jq --arg a "$N_PT" --arg d "$N_TG_TOK" --arg e "$N_TG_ID" \
       '.config.pushplus_token=$a|.config.telegram_bot_token=$d|.config.telegram_chat_id=$e' \
       "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    
    msg_ok "配置已更新，正在重启服务..."
    run_restart
}

run_edit_frequency() {
    check_service_exists
    check_jq
    local CUR=$(jq -r '.config.frequency' "$CONFIG_FILE")
    echo "当前轮询间隔: $CUR 秒"
    read -p "新间隔 (秒, 建议 >= 300): " NEW
    if ! [[ "$NEW" =~ ^[0-9]+$ ]]; then msg_err "无效数字"; return 1; fi
    
    jq --argjson v "$NEW" '.config.frequency=$v' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    msg_ok "频率已更新"
    run_restart
}

run_edit_threads() {
    check_service_exists
    check_jq
    local CUR=$(jq -r '.config.max_workers // 5' "$CONFIG_FILE")
    echo "当前 RSS 并发线程数: $CUR"
    echo -e "${YELLOW}提示: 高并发易触发 429。建议设置 1-3。${NC}"
    read -p "新 RSS 线程数 (1-20): " NEW
    if ! [[ "$NEW" =~ ^[0-9]+$ ]]; then msg_err "无效数字"; return 1; fi
    if [ "$NEW" -lt 1 ] || [ "$NEW" -gt 20 ]; then msg_err "数值超出范围"; return 1; fi
    
    jq --argjson v "$NEW" '.config.max_workers=$v' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    msg_ok "线程数已更新为: $NEW"
    run_restart
}

run_status() {
    check_service_exists
    systemctl status $SERVICE_NAME --no-pager
    if [ -f "$HEARTBEAT_FILE" ]; then
        local DIFF=$(($(date +%s) - $(cat "$HEARTBEAT_FILE")))
        echo -e "\n--- 监控心跳 ---\n上次活跃: ${GREEN}$DIFF 秒前${NC}"
    fi
}

run_logs() {
    check_service_exists
    msg_info "查看实时日志 (Ctrl+C 退出)..."
    sleep 1
    journalctl -u $SERVICE_NAME -f -n 50 --output cat
}

run_view_history() {
    check_service_exists
    msg_info "正在查询最近成功的推送记录 (Limit 20)..."
    local PY_SCRIPT="
import pymongo, os
from datetime import datetime
try:
    client = pymongo.MongoClient(os.getenv('MONGO_HOST', 'mongodb://localhost:27017/'))
    logs = list(client['forum_monitor']['push_logs'].find().sort('created_at', -1).limit(20))
    print('-'*85 + f'\n| {\"Time\":<19} | {\"Type\":<8} | {\"Title\":<50} |\n' + '-'*85)
    if not logs: print('| No push history found.')
    for l in logs:
        ts = l.get('created_at', datetime.now()).strftime('%Y-%m-%d %H:%M:%S')
        t = l.get('title', 'No Title')[:45]
        c = '\033[0;32m' if l.get('type')=='thread' else '\033[0;36m'
        print(f'| {ts:<19} | {c}{l.get(\"type\", \"UNK\"):<8}\033[0m | {t:<50} |')
    print('-'*85)
except Exception as e: print(e)
"
    "$VENV_DIR/bin/python" -c "$PY_SCRIPT"
}

run_repush_active() {
    check_service_exists
    msg_info "正在检索活跃帖子并请求 AI 重新分析 (Single-Thread)..."
    local PY_SCRIPT="
import pymongo, os, sys, time
from datetime import datetime
sys.path.append('$APP_DIR')
from core import ForumMonitor, SHANGHAI
try:
    m = ForumMonitor('$CONFIG_FILE')
    cursor = m.db['threads'].find().sort('pub_date', -1).limit(10)
    cnt = 0
    print('Scanning (Limit 3)...')
    for t in cursor:
        if cnt >= 3: break
        age = (datetime.now(t['pub_date'].tzinfo) - t['pub_date']).total_seconds()
        if age < 86400:
            print(f' -> 🤖 Analyzing: {t.get(\"title\")[:30]}...')
            raw = m.get_summarize_from_ai(t.get('description',''))
            html = m.markdown_to_html(raw).replace('[ORDER_LINK_HERE]','')
            ts = t['pub_date'].astimezone(SHANGHAI).strftime('%Y-%m-%d %H:%M')
            model = m.config.get('ai_provider', 'gemini')
            
            # --- FIX: ESCAPE TITLE & CREATOR ---
            safe_title = t.get('title', '').replace('<', '&lt;').replace('>', '&gt;')
            safe_creator = t.get('creator', 'Unknown').replace('<', '&lt;').replace('>', '&gt;')
            # -----------------------------------
            
            content = f\"<h4 style='color:#d63384;margin:0;'>🔄 [Repush] {safe_title}</h4><div style='font-size:12px;color:#666;'>👤 {safe_creator} | 🕒 {ts} | 🤖 {model}</div><div style='font-size:14px;color:#333;'>{html}</div><div style='margin-top:10px;'><a href='{t['link']}'>👉 查看原帖</a></div>\"
            
            if m.notifier.send_html_message(f'🟡 [Repush] {safe_title}', content):
                m.log_push_history('repush', safe_title, t['link'])
                print('    ✅ Success'); cnt += 1
            time.sleep(2)
    print(f'Done. Repushed {cnt}.')
except Exception as e: print(f'Error: {e}')
"
    "$VENV_DIR/bin/python" -c "$PY_SCRIPT"
}

run_test_push() {
    check_service_exists
    msg_info "正在发送全格式测试通知..."
    local PY_CMD="import sys; sys.path.append('$APP_DIR'); from send import NotificationSender; s=NotificationSender('$CONFIG_FILE'); s.send_html_message('🟡 [TEST] 模拟推送', '<b>测试消息</b><br>如果收到此消息，说明推送通道正常。'); print('✅ 发送尝试完成')"
    "$VENV_DIR/bin/python" -c "$PY_CMD"
}

run_test_ai() {
    check_service_exists
    msg_info "正在测试 AI 连通性..."
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
            msg_err "下载脚本校验失败，取消更新"
            rm -f "$T"
        fi
    else
        msg_err "下载失败，请检查网络"
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
    msg_info "配置 Crontab 保活任务..."
    local CMD="*/5 * * * * $(realpath "$0") monitor >> $APP_DIR/monitor.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "monitor"; echo "$CMD") | crontab -
    msg_ok "已添加每5分钟保活检测"
}

run_uninstall() {
    msg_warn "正在卸载服务及数据..."
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
        jq 'if .config.monitored_roles == null then .config.monitored_roles = ["creator","provider","top_host","host_rep","admin"] else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        
        # Ensure AI fields exist
        jq 'if .config.ai_provider == null then .config.ai_provider = "gemini" else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        jq 'if .config.cf_model == null then .config.cf_model = "@cf/meta/llama-3.1-8b-instruct" else . end' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

        local NEW_THREAD_PROMPT="你是一个中文智能助手。请分析这条 VPS 优惠信息，**必须将所有内容（包括机房、配置）翻译为中文**。请筛选出 1-2 个性价比最高的套餐，并严格按照以下格式输出（不要代码块）：\n\n🏆 **AI 甄选 (高性价比)**：\n• **<套餐名>** (<价格>)：<简短推荐理由>\n\nVPS 列表：\n• **<套餐名>** → <价格> [ORDER_LINK_HERE]\n   └ <核心> / <内存> / <硬盘> / <带宽> / <流量>\n(注意：请在**每一个**识别到的套餐价格后面都加上 [ORDER_LINK_HERE] 占位符。)\n\n限时福利：\n• <优惠码/折扣/活动截止时间>\n\n基础设施：\n• <机房位置> | <IP类型> | <网络特点>\n\n支付方式：\n• <支付手段>\n\n🟢 优点: <简短概括>\n🔴 缺点: <简短概括>\n🎯 适合: <适用人群>"
        local NEW_FILTER_PROMPT="你是一个VPS社区福利分析师。请分析这条回复。只有当内容包含：**补货/降价/新优惠码** (Sales) 或 **抽奖/赠送/免费试用/送余额** (Giveaways/Perks) 等实质性利好时，才提取信息。否则回复 FALSE。如果符合，请务必按以下格式提取（不要代码块）：\n\n🎁 **内容**: <套餐配置/价格 或 奖品/赠品内容>\n🏷️ **代码/规则**: <优惠码 或 参与方式>\n🔗 **链接**: <URL>\n📝 **备注**: <截止时间或简评>"

        jq --arg p "$NEW_THREAD_PROMPT" --arg f "$NEW_FILTER_PROMPT" \
           '.config.thread_prompt = $p | .config.filter_prompt = $f' \
           "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    fi
}

# --- 核心代码写入 (Python: Dual Engine + Title Escape Fix) ---
_write_python_files_and_deps() {
    msg_info "写入 Python 核心代码 (Dual Engine + Title Fix)..."
    
    cat <<'EOF' > "$APP_DIR/$PYTHON_SCRIPT_NAME"
import json
import time
import requests
import cloudscraper
from bs4 import BeautifulSoup
from datetime import datetime, timedelta, timezone
from send import NotificationSender
import os
from pymongo import MongoClient, errors
import shutil
import sys
import re
import google.generativeai as genai
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

        # --- AI Engine Init ---
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

    def load_config(self):
        try:
            if not os.path.exists(self.config_path):
                shutil.copy('example.json', self.config_path)
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

    # --- AI Dispatcher (Dual Engine) ---
    def generate_ai_content(self, system_prompt, user_content, gemini_model_instance=None):
        retries = 5
        delay = 10
        
        for i in range(retries):
            try:
                # Basic throttle
                time.sleep(1) 
                
                if self.ai_provider == 'gemini':
                    if gemini_model_instance:
                        response = gemini_model_instance.generate_content(user_content)
                        return response.text
                    else: return "Gemini Not Initialized"
                
                elif self.ai_provider == 'workers':
                    url = f"https://api.cloudflare.com/client/v4/accounts/{self.cf_account}/ai/run/{self.cf_model}"
                    headers = {"Authorization": f"Bearer {self.cf_token}"}
                    payload = {
                        "messages": [
                            {"role": "system", "content": system_prompt},
                            {"role": "user", "content": user_content}
                        ]
                    }
                    resp = requests.post(url, headers=headers, json=payload, timeout=30)
                    if resp.status_code == 200:
                        res_json = resp.json()
                        return res_json.get("result", {}).get("response", "FALSE")
                    else:
                        raise Exception(f"CF API Error: {resp.status_code} {resp.text}")

            except Exception as e:
                err_str = str(e)
                if "429" in err_str or "quota" in err_str.lower():
                    log(f"⚠️ AI Rate Limit (429). Retrying in {delay}s... ({i+1}/{retries})", YELLOW)
                    time.sleep(delay)
                    delay = int(delay * 1.5)
                else:
                    log(f"❌ AI Error: {e}", RED)
                    return "FALSE"
        
        log(f"❌ AI Failed after {retries} retries.", RED)
        return "FALSE"

    def get_summarize_from_ai(self, description):
        try: 
            # For Gemini, system prompt is set at init, pass object.
            # For Workers, system prompt is passed here.
            gemini_obj = self.model_summary if self.ai_provider == 'gemini' else None
            return self.generate_ai_content(self.thread_prompt, description, gemini_obj)
        except: return "AI Error"

    def get_filter_from_ai(self, description):
        try:
            gemini_obj = self.model_filter if self.ai_provider == 'gemini' else None
            text = self.generate_ai_content(self.filter_prompt, description, gemini_obj).strip()
            return "FALSE" if "FALSE" in text else text
        except: return "FALSE"

    def markdown_to_html(self, text):
        text = text.replace("<", "&lt;").replace(">", "&gt;")
        text = re.sub(r'\*\*(.*?)\*\*', r'<b>\1</b>', text)
        text = text.replace('🏆 AI 甄选 (高性价比)：', '<b>🏆 AI 甄选 (高性价比)：</b>')
        text = text.replace('VPS：', '<b>VPS：</b>')
        text = text.replace('限时福利：', '<b>限时福利：</b>')
        text = text.replace('基础设施：', '<b>基础设施：</b>')
        text = text.replace('支付方式：', '<b>支付方式：</b>')
        text = text.replace('🎁 内容', '<b>🎁 内容</b>')
        text = text.replace('📦 套餐', '<b>📦 套餐</b>')
        text = text.replace('🏷️ 代码', '<b>🏷️ 代码</b>')
        text = text.replace('🏷️ 优惠码', '<b>🏷️ 优惠码</b>')
        text = text.replace('🏷️ 规则', '<b>🏷️ 规则</b>')
        text = text.replace('\n', '<br>')
        return text

    # --- Thread Logic ---
    def handle_thread(self, thread_data, extracted_links):
        try:
            self.threads_collection.insert_one(thread_data)
            now_sh = datetime.now(SHANGHAI)
            pub_date_sh = thread_data['pub_date'].astimezone(SHANGHAI)

            if (now_sh - pub_date_sh).total_seconds() <= 86400:
                log(f"AI 正在摘要: {thread_data['title'][:20]}...", YELLOW, "🤖")
                raw_summary = self.get_summarize_from_ai(thread_data['description'])
                html_summary = self.markdown_to_html(raw_summary)
                
                if extracted_links:
                    parts = html_summary.split("[ORDER_LINK_HERE]")
                    new_summary = parts[0]
                    for i in range(1, len(parts)):
                        if i - 1 < len(extracted_links):
                            link_url = extracted_links[i-1]
                            new_summary += f' <a href="{link_url}" style="color:#007bff;font-weight:bold;">[下单地址]</a>' + parts[i]
                        else: new_summary += parts[i]
                    html_summary = new_summary
                else: html_summary = html_summary.replace("[ORDER_LINK_HERE]", "")

                time_str = pub_date_sh.strftime('%Y-%m-%d %H:%M')
                
                # --- FIX: ESCAPE TITLE & CREATOR ---
                safe_title = thread_data['title'].replace('<', '&lt;').replace('>', '&gt;')
                safe_creator = thread_data['creator'].replace('<', '&lt;').replace('>', '&gt;')
                # -----------------------------------
                
                push_title = f"🟢 [新帖] {safe_title}"
                model_n = self.config.get('model') if self.ai_provider == 'gemini' else self.config.get('cf_model')

                msg_content = (
                    f"<h4 style='color:#2E8B57;margin-bottom:5px;margin-top:0;'>{safe_title}</h4>"
                    f"<div style='font-size:12px;color:#666;margin-bottom:10px;'>"
                    f"👤 Author: {safe_creator} <span style='margin:0 5px;color:#ddd;'>|</span> 🕒 {time_str} (SH) <span style='margin:0 5px;color:#ddd;'>|</span> 🤖 {model_n}"
                    f"</div><div style='font-size:14px;line-height:1.6;color:#333;'>{html_summary}</div>"
                    f"<div style='margin-top:20px;border-top:1px solid #eee;padding-top:10px;'><a href='{thread_data['link']}' style='display:inline-block;padding:8px 15px;background:#2E8B57;color:white;text-decoration:none;border-radius:4px;font-weight:bold;'>👉 查看原帖 (Source)</a></div>"
                )
                
                if self.notifier.send_html_message(push_title, msg_content):
                    self.log_push_history("thread", thread_data['title'], thread_data['link'])

            return True 
        except errors.DuplicateKeyError: return False
        except: return False

    def handle_comment(self, comment_data, thread_data, created_at_sh):
        try:
            self.comments_collection.insert_one(comment_data)
            log(f"   ✅ [新回复] {comment_data['author']} (活跃中...)", GREEN)
            
            if not comment_data['message'].strip(): return

            ai_resp = self.get_filter_from_ai(comment_data['message'])
            if "FALSE" not in ai_resp:
                log(f"      🚀 关键词匹配! 推送中...", GREEN)
                ai_resp_html = self.markdown_to_html(ai_resp)
                time_str = created_at_sh.strftime('%Y-%m-%d %H:%M')
                
                # --- FIX: ESCAPE STRINGS ---
                thread_provider = thread_data.get('creator', 'Unknown').replace('<', '&lt;').replace('>', '&gt;')
                reply_author = comment_data['author'].replace('<', '&lt;').replace('>', '&gt;')
                safe_thread_title = thread_data['title'].replace('<', '&lt;').replace('>', '&gt;')
                # ---------------------------
                
                if reply_author == thread_provider:
                    push_title = f"🔵 [{thread_provider}] 楼主新回复"
                    header_color = "#007bff"
                else:
                    push_title = f"🔴 [{thread_provider}] ⚡插播({reply_author})"
                    header_color = "#d63384"
                
                model_n = self.config.get('model') if self.ai_provider == 'gemini' else self.config.get('cf_model')

                msg_content = (
                    f"<h4 style='color:{header_color};margin-bottom:5px;'>💬 {push_title}</h4>"
                    f"<div style='font-size:12px;color:#666;margin-bottom:10px;'>"
                    f"📌 Source: {safe_thread_title} <span style='margin:0 5px;color:#ddd;'>|</span> 🕒 {time_str} (SH) <span style='margin:0 5px;color:#ddd;'>|</span> 🤖 {model_n}"
                    f"</div>"
                    f"<div style='background:#f8f9fa;padding:10px;border:1px solid #eee;border-radius:5px;color:#333;'><b>🤖 AI 分析:</b><br>{ai_resp_html}</div>"
                    f"<div style='margin-top:15px;'><a href='{comment_data['url']}' style='color:{header_color};'>👉 查看回复</a></div>"
                )
                
                if self.notifier.send_html_message(push_title, msg_content):
                    self.log_push_history("reply", f"{push_title}", comment_data['url'])
                    
        except errors.DuplicateKeyError: pass 
        except: pass

    # --- Scanning Logic ---
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
                
                comment_classes = comment.get('class', [])
                class_str = " ".join(comment_classes).lower()
                
                if 'role_patronprovider' in class_str or 'role_provider' in class_str: role_hits.append('provider')
                if 'role_tophost' in class_str: role_hits.append('top_host')
                if 'role_hostrep' in class_str: role_hits.append('host_rep')
                if 'role_administrator' in class_str or author_name.lower() == 'administrator': role_hits.append('admin')
                if not role_hits: role_hits.append('other')
                
                should_process = False
                if any(r in enabled_roles for r in role_hits): should_process = True
                if is_target_user: should_process = True
                if not should_process: continue

                comment_id = comment['id'].replace('Comment_', '')
                
                msg_div = comment.find('div', class_='Message')
                if msg_div:
                    for quote in msg_div.find_all('blockquote'):
                        quote.decompose()
                    message = msg_div.get_text(separator=' ', strip=True)
                else: message = ""
                
                permalink_url = f"https://lowendtalk.com/discussion/comment/{comment_id}/#Comment_{comment_id}"

                c_data = {
                    'comment_id': comment_id, 'thread_link': thread_data['link'],
                    'author': author_name, 'message': message, 'created_at': created_at_aware, 
                    'url': permalink_url
                }
                self.handle_comment(c_data, thread_data, created_at_sh)
            except: pass
        return found_recent

    def get_max_page_from_soup(self, soup):
        try:
            pager = soup.find('div', class_='Pager')
            if not pager: return 1
            links = pager.find_all('a')
            pages = []
            for a in links:
                txt = a.get_text(strip=True)
                if txt.isdigit(): pages.append(int(txt))
            if pages: return max(pages)
            return 1
        except: return 1

    def fetch_comments(self, thread_data, silent=False):
        self.processed_urls_this_cycle.add(thread_data['link'])
        if thread_data['creator'] == 'Unknown':
             stored = self.threads_collection.find_one({'link': thread_data['link']})
             if stored and 'creator' in stored: thread_data['creator'] = stored['creator']

        REQ_TIMEOUT = 15
        try:
            time.sleep(1 if silent else 0.2)
            resp = self.scraper.get(thread_data['link'], timeout=REQ_TIMEOUT)
            if resp.status_code != 200: return False
            
            soup = BeautifulSoup(resp.text, 'html.parser')
            max_page = self.get_max_page_from_soup(soup)
            target_limit = max(1, max_page - 2)
            for page in range(max_page, target_limit - 1, -1):
                page_start = time.time()
                if page == 1 and max_page == 1: content = resp.text
                else:
                    time.sleep(0.2)
                    page_url = f"{thread_data['link']}/p{page}"
                    p_resp = self.scraper.get(page_url, timeout=REQ_TIMEOUT)
                    if p_resp.status_code != 200: continue
                    content = p_resp.text

                has_recent = self.parse_let_comment(content, thread_data)
                page_dur = time.time() - page_start
                if not silent: 
                    author = thread_data.get('creator', 'Unknown')
                    title = thread_data.get('title', 'Unknown')
                    log(f"   📄 {WHITE}@{author}{NC} {CYAN}{title[:30]}...{NC} | P{page}/{max_page} | {page_dur:.2f}s", GRAY)
                if not has_recent: break
            return True
        except Exception as e: return False

    def process_rss_item(self, item_str):
        try:
            item_soup = BeautifulSoup(item_str, 'xml')
            title = item_soup.find('title').get_text()
            link = item_soup.find('link').get_text()
            creator = "Unknown"
            c_tag = item_soup.find('dc:creator') or item_soup.find('creator') or item_soup.find('author')
            if c_tag: creator = c_tag.get_text(strip=True)
            date_str = item_soup.find('pubDate').get_text()
            pub_date = datetime.strptime(date_str, "%a, %d %b %Y %H:%M:%S %z")
            desc = item_soup.find('description').get_text() if item_soup.find('description') else ""
            desc_text = BeautifulSoup(desc, 'html.parser').get_text(separator=" ", strip=True)

            t_data = {
                'cate': 'let', 'title': title, 'link': link, 'description': desc_text,
                'pub_date': pub_date, 'created_at': datetime.utcnow(), 'creator': creator, 'last_page': 1
            }
            self.processed_urls_this_cycle.add(link)
            age = (datetime.now(timezone.utc) - pub_date).total_seconds()

            if self.threads_collection.find_one({'link': link}):
                is_processed = self.fetch_comments(t_data, silent=(age > 86400))
                return "SILENT" if (age > 86400 and is_processed) else "ACTIVE"
            else:
                if age <= 86400:
                    self.handle_thread(t_data, [])
                    return "NEW_PUSH"
                else:
                    self.threads_collection.insert_one(t_data)
                    self.fetch_comments(t_data, silent=True)
                    return "OLD_SAVED"
        except Exception as e: return "ERROR"

    def check_rss(self):
        try:
            start_t = time.time()
            max_w = self.config.get('max_workers', 3) 
            resp = self.scraper.get("https://lowendtalk.com/categories/offers/feed.rss", timeout=30)
            if resp.status_code == 200:
                soup = BeautifulSoup(resp.text, 'xml')
                items = soup.find_all('item')
                log(f"RSS 扫描开始 | 目标: {len(items)} | 线程数: {max_w}", BLUE, "📡")
                stats = {"SILENT": 0, "ACTIVE": 0, "NEW_PUSH": 0, "ERROR": 0, "OLD_SAVED": 0}
                with ThreadPoolExecutor(max_workers=max_w) as executor:
                    futures = [executor.submit(self.process_rss_item, str(i)) for i in items]
                    for f in as_completed(futures):
                        res = f.result()
                        if res in stats: stats[res] += 1
                duration = time.time() - start_t
                log(f"RSS 扫描完成 | 耗时: {duration:.2f}s | 新帖:{stats['NEW_PUSH']} | 活跃:{stats['ACTIVE']} | 静默:{stats['SILENT']}", GREEN)
        except Exception as e: log(f"RSS Error: {e}", RED, "❌")

    def check_vip_threads(self):
        vip_urls = self.config.get('vip_threads', [])
        if not vip_urls: return
        log(f"VIP 专线扫描开始 ({len(vip_urls)} urls)...", MAGENTA, "👑")
        for url in vip_urls:
            try:
                resp = self.scraper.get(url, timeout=30)
                if resp.status_code != 200: continue
                soup = BeautifulSoup(resp.text, 'html.parser')
                title_tag = soup.select_one('.PageTitle h1')
                if not title_tag: continue
                title = title_tag.get_text(strip=True)
                creator = "Unknown"
                author_tag = soup.select_one('.Author .Username')
                if author_tag: creator = author_tag.get_text(strip=True)
                t_data = {'link': url, 'title': title, 'creator': creator, 'pub_date': datetime.now(timezone.utc)}
                self.threads_collection.update_one({'link': url}, {'$setOnInsert': t_data}, upsert=True)
                self.fetch_comments(t_data, silent=False)
            except Exception as e: log(f"VIP Scan Error: {e}", RED, "❌")

    def check_category_list(self):
        target_urls = ["https://lowendtalk.com/categories/offers", "https://lowendtalk.com/categories/announcements"]
        log(f"列表页扫描开始 ({len(target_urls)} categories)...", MAGENTA, "🔎")
        start_t = time.time()
        for url in target_urls:
            try:
                log(f"   -> 正在扫描: {url} ...", GRAY)
                resp = self.scraper.get(url, timeout=30)
                if resp.status_code != 200: continue
                soup = BeautifulSoup(resp.text, 'html.parser')
                discussions = soup.select('.ItemDiscussion')
                if not discussions: discussions = soup.find_all('li', class_='Discussion')
                if not discussions: discussions = soup.select('tr.ItemDiscussion')
                candidates = []
                for d in discussions:
                    try:
                        a_tag = d.select_one('.DiscussionName a') or d.find('h3', class_='DiscussionName').find('a')
                        if not a_tag: continue
                        link = a_tag['href']
                        if not link.startswith('http'): link = "https://lowendtalk.com" + link
                        title = a_tag.get_text(strip=True)
                        if link in self.processed_urls_this_cycle: continue
                        last_date_tag = d.find('span', class_='LastCommentDate')
                        if not last_date_tag: last_date_tag = d.select_one('.DateUpdated')
                        if last_date_tag:
                            time_tag = last_date_tag.find('time')
                            if time_tag and time_tag.has_attr('datetime'):
                                dt_str = time_tag['datetime']
                                last_active = datetime.strptime(dt_str, "%Y-%m-%dT%H:%M:%S%z")
                                now = datetime.now(timezone.utc)
                                if (now - last_active).total_seconds() < 86400 * 2: 
                                    creator = "Unknown"
                                    first_user = d.find('span', class_='FirstUser') or d.select_one('.Author a')
                                    if first_user: creator = first_user.get_text(strip=True)
                                    candidates.append({'link': link, 'title': title, 'creator': creator, 'last_page': 1})
                    except: continue
                log(f"      ⚡ 命中候选: {len(candidates)} 个", GRAY)
                if candidates:
                    log(f"      ⚠️ 启动深度抓取 (单线程)...", YELLOW)
                    for t in candidates: self.fetch_comments(t, silent=False)
            except Exception as e: log(f"Category Scan Error ({url}): {e}", RED, "❌")
        duration = time.time() - start_t
        log(f"列表页扫描完成 | 总耗时: {duration:.2f}s", MAGENTA)

    def start_monitoring(self):
        log("=== 监控服务启动 (v34: Menu Reordered) ===", GREEN, "🚀")
        freq = self.config.get('frequency', 300)
        while True:
            cycle_start = time.time()
            self.processed_urls_this_cycle.clear()
            print(f"{GRAY}--------------------------------------------------{NC}")
            self.check_rss()
            self.check_vip_threads()
            self.check_category_list()
            self.update_heartbeat()
            cycle_end = time.time()
            total_time = cycle_end - cycle_start
            log(f"⏱️ 本轮扫描总耗时: {total_time:.2f}s | 休眠 {freq}秒...", YELLOW)
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
EOF

    msg_info "写入推送模块 (Pushplus + Telegram Fix)..."
    cat <<'EOF' > "$APP_DIR/send.py"
import json
import requests
import os
import re
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from datetime import datetime

GREEN = '\033[0;32m'
RED = '\033[0;31m'
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
        if not self.tg_bot_token or not self.tg_chat_id: return False
        try:
            msg = f"<b>{title}</b>\n\n{html_content}"
            msg = msg.replace("<br>", "\n").replace("<br/>", "\n")
            msg = re.sub(r'<h4.*?>(.*?)</h4>', r'<b>\1</b>\n', msg, flags=re.DOTALL)
            msg = re.sub(r'<div.*?>', '', msg).replace('</div>', '\n')
            msg = re.sub(r'<span.*?>', '', msg).replace('</span>', ' ')
            while "\n\n\n" in msg: msg = msg.replace("\n\n\n", "\n\n")

            messages = []
            MAX_LEN = 4000
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
                header = f"[Part {i+1}/{len(messages)}]\n" if len(messages) > 1 and i > 0 else ""
                url = f"https://api.telegram.org/bot{self.tg_bot_token}/sendMessage"
                payload = {'chat_id': self.tg_chat_id, 'text': header + part, 'parse_mode': 'HTML', 'disable_web_page_preview': True}
                resp = self.session.post(url, json=payload, timeout=15)
                if resp.status_code == 200: log(f"Telegram Sent: {title[:30]}... (Part {i+1})", GREEN, "✈️")
                else: log(f"Telegram Fail: {resp.text}", RED, "❌"); all_success = False
            return all_success
        except Exception as e: log(f"Telegram Error: {e}", RED, "❌"); return False

    def send_html_message(self, title, html_content):
        success_count = 0
        if self.pushplus_token and self.pushplus_token != "YOUR_PUSHPLUS_TOKEN_HERE":
            try:
                pp_title = title[:92] + "..." if len(title) > 95 else title
                payload = {"token": self.pushplus_token, "title": pp_title, "content": html_content, "template": "html"}
                resp = self.session.post("https://www.pushplus.plus/send", json=payload, timeout=15)
                if resp.status_code == 200 and resp.json().get('code') == 200:
                    log(f"Pushplus Sent: {title[:30]}...", GREEN, "📨"); success_count += 1
                else: 
                    if "用户账号使用受限" in resp.text:
                         log(f"Pushplus Quota Limit (Ignored)", YELLOW, "⚠️")
                    else:
                         log(f"Pushplus Fail: {resp.text}", RED, "❌")
            except Exception as e: log(f"Pushplus Error: {e}", RED, "❌")

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
    msg_info "=== 开始部署 ForumMonitor (v34 Edition) ==="
    
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
        read -p "请输入 Pushplus Token: " PT
        echo -e "${YELLOW}Telegram 配置 (留空跳过)${NC}"
        read -p "Telegram Bot Token: " TG_TOK
        read -p "Telegram Chat ID: " TG_ID
        read -p "请输入 Gemini API Key: " GK
        # UPDATE: 新安装时使用新的 Prompt 和默认参数
        local PROMPT="你是一个中文智能助手。请分析这条 VPS 优惠信息，**必须将所有内容（包括机房、配置）翻译为中文**。请筛选出 1-2 个性价比最高的套餐，并严格按照以下格式输出（不要代码块）：\n\n🏆 **AI 甄选 (高性价比)**：\n• **<套餐名>** (<价格>)：<简短推荐理由>\n\nVPS 列表：\n• **<套餐名>** → <价格> [ORDER_LINK_HERE]\n   └ <核心> / <内存> / <硬盘> / <带宽> / <流量>\n(注意：请在**每一个**识别到的套餐价格后面都加上 [ORDER_LINK_HERE] 占位符。)\n\n限时福利：\n• <优惠码/折扣/活动截止时间>\n\n基础设施：\n• <机房位置> | <IP类型> | <网络特点>\n\n支付方式：\n• <支付手段>\n\n🟢 优点: <简短概括>\n🔴 缺点: <简短概括>\n🎯 适合: <适用人群>"
        
        jq -n --arg pt "$PT" --arg gk "$GK" --arg prompt "$PROMPT" --arg tt "$TG_TOK" --arg ti "$TG_ID" \
           '{config: {pushplus_token: $pt, telegram_bot_token: $tt, telegram_chat_id: $ti, gemini_api_key: $gk, model: "gemini-2.0-flash-lite", ai_provider: "gemini", cf_account_id: "", cf_api_token: "", cf_model: "@cf/meta/llama-3.1-8b-instruct", thread_prompt: $prompt, filter_prompt: "内容：XXX", frequency: 300, vip_threads: [], monitored_roles: ["creator","provider","top_host","host_rep","admin"], monitored_usernames: []}}' > "$CONFIG_FILE"
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
    
    msg_ok "安装完成! 正在重新加载管理脚本..."
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
    printf "  %-4s %-12s %b%s%b\n" "3." "update" "$GRAY" "更新代码(应用补丁)" "$NC"
    
    echo -e "${CYAN} [服务控制]${NC}"
    printf "  %-4s %-12s %b%s%b\n" "4." "start" "$GRAY" "启动服务" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "5." "stop" "$GRAY" "停止服务" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "6." "restart" "$GRAY" "重启服务" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "7." "status" "$GRAY" "详细状态" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "8." "logs" "$GRAY" "实时日志" "$NC"

    echo -e "${CYAN} [配置管理]${NC}"
    printf "  %-4s %-12s %b%s%b\n" "9." "edit" "$GRAY" "修改推送/基础配置" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "10." "ai-switch" "$GRAY" "切换 AI 引擎(Gemini/Workers)" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "11." "frequency" "$GRAY" "调整频率" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "12." "threads" "$GRAY" "修改线程数" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "13." "keepalive" "$GRAY" "开启保活" "$NC"

    echo -e "${CYAN} [监控规则]${NC}"
    printf "  %-4s %-12s %b%s%b\n" "14." "vip" "$GRAY" "管理VIP专线" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "15." "roles" "$GRAY" "管理监控角色" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "16." "users" "$GRAY" "管理指定用户" "$NC"

    echo -e "${CYAN} [功能测试]${NC}"
    printf "  %-4s %-12s %b%s%b\n" "17." "test-ai" "$GRAY" "测试 AI 连通性" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "18." "test-push" "$GRAY" "测试消息推送" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "19." "history" "$GRAY" "查看推送历史" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "20." "repush" "$GRAY" "手动推送活跃帖" "$NC"

    echo -e "${GRAY}----------------------------------------------------------------${NC}"
    echo -e "  q. quit         退出"
}

main() {
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
            vip|14) run_manage_vip ;;
            roles|15) run_manage_roles ;;
            users|16) run_manage_users ;;
            test-ai|17) run_test_ai ;;
            test-push|18) run_test_push ;;
            history|19) run_view_history; read -n 1 -s -r -p "完成..." ;;
            repush|20) run_repush_active; read -n 1 -s -r -p "完成..." ;;
            update|3) run_apply_app_update; read -n 1 -s -r -p "完成..." ;; 
            monitor) run_monitor_logic ;;
            *) show_menu; exit 1 ;;
        esac; exit 0
    fi

    while true; do
        show_menu
        echo -e -n "${YELLOW}请输入选项: ${NC}"
        read CMD
        case "$CMD" in
            1) run_install; read -n 1 -s -r -p "完成..." ;;
            2) run_uninstall; exit 0 ;;
            3) run_apply_app_update; read -n 1 -s -r -p "完成..." ;;
            4) run_start; read -n 1 -s -r -p "完成..." ;;
            5) run_stop; read -n 1 -s -r -p "完成..." ;;
            6) run_restart; read -n 1 -s -r -p "完成..." ;;
            7) run_status; read -n 1 -s -r -p "完成..." ;;
            8) run_logs; read -n 1 -s -r -p "完成..." ;;
            9) run_edit_config; read -n 1 -s -r -p "完成..." ;;
            10) run_ai_switch ;;
            11) run_edit_frequency; read -n 1 -s -r -p "完成..." ;;
            12) run_edit_threads; read -n 1 -s -r -p "完成..." ;;
            13) run_setup_keepalive; read -n 1 -s -r -p "完成..." ;;
            14) run_manage_vip ;;
            15) run_manage_roles ;;
            16) run_manage_users ;;
            17) run_test_ai; read -n 1 -s -r -p "完成..." ;;
            18) run_test_push; read -n 1 -s -r -p "完成..." ;;
            19) run_view_history; read -n 1 -s -r -p "按任意键返回..." ;;
            20) run_repush_active; read -n 1 -s -r -p "按任意键返回..." ;;
            q|Q) break ;;
            *) ;;
        esac
    done
}

main "$@"
