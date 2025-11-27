#!/bin/bash

# --- ForumMonitor 管理脚本 (Gemini 2.5 Flash Lite Edition) ---
# Version: 2025.11.27.9
# Features: 
# [x] Anti-WAF (CloudScraper)
# [x] Strict Sales Filter & AI Picks
# [x] True Reverse Scan (Smart Stop)
# [x] Push Verification & History Log
# [x] Dynamic Reply Titles (Provider Name)
# [x] Full AI Repush (Same format as live alerts)
# [x] Single-Threaded Repush Lock
# [x] Auto Title Truncation
# [x] Detailed Error Logging for AI (Debug Mode)
# [x] Default Model: gemini-2.5-flash-lite
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
UPDATE_URL="https://raw.githubusercontent.com/ypkin/ForumMonitor-LET/refs/heads/main/ForumMonitor.sh"

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
    
    local CUR_MODEL="Unknown"
    local CUR_THREADS="5"
    if [ -f "$CONFIG_FILE" ]; then
        CUR_MODEL=$(jq -r '.config.model // "gemini-2.5-flash-lite"' "$CONFIG_FILE")
        CUR_THREADS=$(jq -r '.config.max_workers // 5' "$CONFIG_FILE")
    fi

    echo -e "${BLUE}================================================================${NC}"
    echo -e " ${CYAN}ForumMonitor (Gemini 2.5 Flash Lite)${NC}"
    echo -e "${BLUE}================================================================${NC}"
    printf " %-16s %b%-20s%b | %-16s %b%-10s%b\n" "运行状态:" "$STATUS_COLOR" "$STATUS_TEXT" "$NC" "已推送通知:" "$GREEN" "$PUSH_COUNT" "$NC"
    printf " %-16s %b%-20s%b | %-16s %b%-10s%b\n" "运行持续:" "$YELLOW" "$UPTIME" "$NC" "自动重启:" "$RED" "$RESTART_COUNT 次" "$NC"
    printf " %-16s %b%-20s%b | %-16s %b%-10s%b\n" "当前模型:" "$CYAN" "$CUR_MODEL" "$NC" "RSS并发数:" "$CYAN" "$CUR_THREADS" "$NC"
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

run_edit_config() {
    check_service_exists
    check_jq
    echo "--- 修改配置 (直接回车保留原值) ---"
    
    local C_PT=$(jq -r '.config.pushplus_token' "$CONFIG_FILE")
    local C_GK=$(jq -r '.config.gemini_api_key' "$CONFIG_FILE")
    local C_MODEL=$(jq -r '.config.model // "gemini-2.5-flash-lite"' "$CONFIG_FILE")

    read -p "Pushplus Token (当前: ***${C_PT: -6}): " N_PT
    read -p "Gemini API Key (当前: ***${C_GK: -6}): " N_GK
    echo -e "${YELLOW}提示: 默认模型 gemini-2.5-flash-lite${NC}"
    read -p "Gemini Model Name (当前: $C_MODEL): " N_MODEL

    [ -z "$N_PT" ] && N_PT="$C_PT"
    [ -z "$N_GK" ] && N_GK="$C_GK"
    [ -z "$N_MODEL" ] && N_MODEL="$C_MODEL"

    # 使用临时文件确保原子写入
    jq --arg a "$N_PT" --arg b "$N_GK" --arg c "$N_MODEL" \
       '.config.pushplus_token=$a|.config.gemini_api_key=$b|.config.model=$c' \
       "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    
    msg_ok "配置已更新，正在重启服务..."
    run_restart
}

run_edit_frequency() {
    check_service_exists
    check_jq
    local CUR=$(jq -r '.config.frequency' "$CONFIG_FILE")
    echo "当前轮询间隔: $CUR 秒"
    read -p "新间隔 (秒): " NEW
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
    echo -e "${YELLOW}提示: 仅影响 RSS 扫描。列表页扫描已锁定为单线程以防封禁。${NC}"
    read -p "新 RSS 线程数 (1-20): " NEW
    
    if ! [[ "$NEW" =~ ^[0-9]+$ ]]; then 
        msg_err "无效数字"; return 1; 
    fi
    
    if [ "$NEW" -lt 1 ] || [ "$NEW" -gt 20 ]; then
        msg_err "数值超出范围，请输入 1-20 之间的数字。"
        return 1
    fi
    
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
import pymongo
import os
from datetime import datetime
import sys

try:
    client = pymongo.MongoClient(os.getenv('MONGO_HOST', 'mongodb://localhost:27017/'))
    db = client['forum_monitor']
    logs = list(db['push_logs'].find().sort('created_at', -1).limit(20))
    
    sep = '-' * 85
    print('')
    print(sep)
    print(f'| {\"Time\":<19} | {\"Type\":<8} | {\"Title (Provider/Subject)\":<50} |')
    print(sep)
    
    if not logs:
        print('| No push history found yet.                                                        |')
    
    for log in logs:
        time_str = log.get('created_at', datetime.now()).strftime('%Y-%m-%d %H:%M:%S')
        l_type = log.get('type', 'UNK')
        title = log.get('title', 'No Title')
        if len(title) > 48: title = title[:45] + '...'
        
        c_green = '\033[0;32m'
        c_cyan = '\033[0;36m'
        c_yellow = '\033[0;33m'
        c_gray = '\033[0;90m'
        c_end = '\033[0m'
        
        color = c_gray
        if l_type == 'thread': color = c_green
        elif l_type == 'reply': color = c_cyan
        elif l_type == 'repush': color = c_yellow

        print(f'| {time_str:<19} | {color}{l_type:<8}{c_end} | {title:<50} |')
    
    print(sep)
    print('')
except Exception as e:
    print(f'Error: {e}')
"
    "$VENV_DIR/bin/python" -c "$PY_SCRIPT"
}

run_repush_active() {
    check_service_exists
    msg_info "正在检索活跃帖子并请求 AI 重新分析 (Single-Thread)..."
    msg_warn "注意：为了生成完整报告，系统将重新调用 Gemini API。"
    msg_warn "为防风控，限制处理最新的 3 条 Active 记录。"
    
    local PY_SCRIPT="
import pymongo
import os
import sys
import time
from datetime import datetime, timedelta, timezone

# Add APP_DIR to path to import core/send
sys.path.append('$APP_DIR')
from core import ForumMonitor, SHANGHAI

try:
    # Instantiate Core to use Gemini & DB Logic
    monitor = ForumMonitor('$CONFIG_FILE')
    
    # Logic: Get threads sorted by pub_date DESC
    cursor = monitor.db['threads'].find().sort('pub_date', -1).limit(10)
    
    count = 0
    max_repush = 3
    
    print(f'Scanning and re-analyzing threads (Limit: {max_repush})...')
    
    for t in cursor:
        if count >= max_repush: break
        
        pub_date = t.get('pub_date')
        if not pub_date: continue
        
        # Handle timezone mixing
        now = datetime.now(pub_date.tzinfo) if pub_date.tzinfo else datetime.utcnow()
        age = (now - pub_date).total_seconds()
        
        if age < 86400: # 24 hours
            title = t.get('title', 'No Title')
            link = t.get('link', '#')
            creator = t.get('creator', 'Unknown')
            desc = t.get('description', '')
            
            print(f' -> 🤖 Analyzing: {title[:40]}...')
            
            # 1. Call AI Summary
            raw_summary = monitor.get_summarize_from_ai(desc)
            
            # 2. Convert Markdown to HTML
            html_summary = monitor.markdown_to_html(raw_summary)
            
            # 3. Clean up placeholders (Since we don't have extracted links list here easily)
            html_summary = html_summary.replace('[ORDER_LINK_HERE]', '')
            
            # 4. Build Full HTML Payload (Matching core.py)
            pub_date_sh = pub_date.astimezone(SHANGHAI) if pub_date.tzinfo else pub_date
            time_str = pub_date_sh.strftime('%Y-%m-%d %H:%M')
            model_name = monitor.config.get('model', 'Unknown')
            
            msg_content = (
                f\"<h4 style='color:#d63384;margin-bottom:5px;margin-top:0;'>🔄 [Repush] {title}</h4>\"
                f\"<div style='font-size:12px;color:#666;margin-bottom:10px;'>\"
                f\"👤 Author: {creator} <span style='margin:0 5px;color:#ddd;'>|</span> 🕒 {time_str} (SH) <span style='margin:0 5px;color:#ddd;'>|</span> 🤖 {model_name}\"
                f\"</div><div style='font-size:14px;line-height:1.6;color:#333;'>{html_summary}</div>\"
                f\"<div style='margin-top:20px;border-top:1px solid #eee;padding-top:10px;'><a href='{link}' style='display:inline-block;padding:8px 15px;background:#d63384;color:white;text-decoration:none;border-radius:4px;font-weight:bold;'>👉 查看原帖 (Source)</a></div>\"
            )
            
            # 5. Send (Title truncated automatically by send.py if needed)
            if monitor.notifier.send_html_message(f'[Repush] {title}', msg_content):
                monitor.log_push_history('repush', title, link)
                print('    ✅ Success')
                count += 1
            else:
                print('    ❌ Failed to send')
                
            # Sleep slightly between repushes to be safe
            time.sleep(2)
        else:
            pass
            
    if count == 0:
        print('No recent active threads found ( < 24h ).')
    else:
        print(f'Done. AI Repushed {count} threads.')

except Exception as e:
    print(f'Error: {e}')
"
    "$VENV_DIR/bin/python" -c "$PY_SCRIPT"
}

# --- 测试功能 ---

run_test_push() {
    check_service_exists
    check_jq
    msg_info "正在发送全格式测试通知..."
    
    local TITLE="[TEST] 模拟: Gemini 2.5 Flash Lite (含历史记录写入)"
    local CUR_TIME=$(date "+%Y-%m-%d %H:%M")
    local MODEL=$(jq -r '.config.model // "gemini-2.5-flash-lite"' "$CONFIG_FILE")
    
    local CONTENT="<h4 style='color:#2E8B57;margin-bottom:5px;margin-top:0;'>📢 [TEST] History Log Verification</h4><div style='font-size:12px;color:#666;margin-bottom:10px;'>👤 Author: Admin <span style='margin:0 5px;color:#ddd;'>|</span> 🕒 $CUR_TIME (SH) <span style='margin:0 5px;color:#ddd;'>|</span> 🤖 $MODEL</div><div style='font-size:14px;line-height:1.6;color:#333;'>这是一条测试消息，发送成功后将自动写入 MongoDB 的 push_logs 集合，以便在菜单 Option 15 中查看。<br><br><b>验证点：</b><br>1. 手机/微信是否收到推送。<br>2. 菜单 15 是否显示此条记录。</div>"
    
    local PY_COMMAND="
import sys
import os
import datetime
from pymongo import MongoClient
sys.path.append('$APP_DIR')
from send import NotificationSender

sender = NotificationSender('$CONFIG_FILE')
success = sender.send_html_message('$TITLE', \"\"\"$CONTENT\"\"\")

if success:
    print('✅ 推送发送成功')
    try:
        client = MongoClient(os.getenv('MONGO_HOST', 'mongodb://localhost:27017/'))
        db = client['forum_monitor']
        db['push_logs'].insert_one({
            'type': 'test',
            'title': '$TITLE',
            'url': 'https://lowendtalk.com',
            'created_at': datetime.datetime.now()
        })
        print('✅ 已写入历史记录 (push_logs)')
    except Exception as e:
        print(f'❌ 写入历史记录失败: {e}')
else:
    print('❌ 推送发送失败')
"
    
    "$VENV_DIR/bin/python" -c "$PY_COMMAND"
}

run_test_ai() {
    check_service_exists
    check_jq
    msg_info "正在测试 Gemini API 连通性..."
    local CMD="import sys; sys.path.append('$APP_DIR'); from core import ForumMonitor; print(ForumMonitor(config_path='$CONFIG_FILE').get_filter_from_ai(\"This is a test message to check connectivity.\"))"
    
    set +e
    local RES=$("$VENV_DIR/bin/python" -c "$CMD" 2>&1)
    set -e
    
    echo "API Response: $RES"
    if [[ "$RES" == *"FALSE"* ]]; then
        msg_ok "AI 响应正常 (拦截测试成功)"
    else
        msg_ok "AI 响应成功 (内容生成)"
    fi
}

# --- 维护功能 ---

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
        echo "$(date): [Watchdog] 服务僵死 (${DIFF}s 未响应). 正在重启..."
        echo "$(date '+%Y-%m-%d %H:%M:%S')" >> "$RESTART_LOG_FILE"
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
        # Prompt 1: 新帖摘要 (增加 AI 甄选)
        local NEW_THREAD_PROMPT="你是一个中文智能助手。请分析这条 VPS 优惠信息，**必须将所有内容（包括机房、配置）翻译为中文**。请筛选出 1-2 个性价比最高的套餐，并严格按照以下格式输出（不要代码块）：\n\n🏆 **AI 甄选 (高性价比)**：\n• **<套餐名>** (<价格>)：<简短推荐理由>\n\nVPS 列表：\n• **<套餐名>** → <价格> [ORDER_LINK_HERE]\n   └ <核心> / <内存> / <硬盘> / <带宽> / <流量>\n(注意：请在**每一个**识别到的套餐价格后面都加上 [ORDER_LINK_HERE] 占位符。)\n\n限时福利：\n• <优惠码/折扣/活动截止时间>\n\n基础设施：\n• <机房位置> | <IP类型> | <网络特点>\n\n支付方式：\n• <支付手段>\n\n🟢 优点: <简短概括>\n🔴 缺点: <简短概括>\n🎯 适合: <适用人群>"
        
        # Prompt 2: 回复过滤 (严格版)
        local NEW_FILTER_PROMPT="你是一个冷酷的销售筛选器。请分析这条VPS论坛回复。只有当回复内容明确包含：**补货 (Restock)**、**加库存 (Added stock)**、**新套餐 (New Plan)**、**降价/闪购** 或 **新优惠码** 等实质性销售动作时，才输出简短中文摘要。\n\n对于以下情况，请必须直接回复 FALSE：\n1. 修复链接、修改排版、修正拼写错误 (Fixed link/typo)\n2. 回答技术问题、工单状态或一般性客服回复\n3. 没有任何具体库存变动的预告（如“Soon”或“Stay tuned”）\n4. 纯粹的感谢、闲聊或表情\n\n**如果不涉及具体的‘可购买’信息变动，一律 FALSE。**"

        jq --arg p "$NEW_THREAD_PROMPT" --arg f "$NEW_FILTER_PROMPT" \
           '.config.thread_prompt = $p | .config.filter_prompt = $f' \
           "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    fi
}

# --- 核心代码写入 (Python) ---
_write_python_files_and_deps() {
    msg_info "写入 Python 核心代码 (With Debug Logging)..."
    
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
        # 新增推送记录集合
        self.push_logs = self.db['push_logs']
        
        self.processed_urls_this_cycle = set()
        
        # CloudScraper Init
        self.scraper = cloudscraper.create_scraper(
            browser={'browser': 'chrome', 'platform': 'windows', 'desktop': True}
        )
        self.scraper.headers.update({
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'en-US,en;q=0.9',
            'Referer': 'https://lowendtalk.com/',
        })

        # Gemini Init
        try:
            api_key = self.config.get('gemini_api_key')
            model_name = self.config.get('model', 'gemini-2.5-flash-lite')
            if api_key:
                genai.configure(api_key=api_key)
                self.model_summary = genai.GenerativeModel(model_name, system_instruction=self.config.get('thread_prompt', ''))
                self.model_filter = genai.GenerativeModel(model_name, system_instruction=self.config.get('filter_prompt', ''))
                log(f"Gemini Loaded ({model_name})", GREEN, "🧠")
        except Exception: pass

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
                'type': p_type,
                'title': title,
                'url': url,
                'created_at': datetime.now(SHANGHAI)
            })
        except: pass

    # --- AI & Tooling (Patched for Debugging) ---
    def get_summarize_from_ai(self, description):
        try: 
            return self.model_summary.generate_content(description).text
        except Exception as e:
            log(f"AI Summary Error: {e}", RED, "❌")
            return f"AI 摘要失败: {str(e)[:50]}..."

    def get_filter_from_ai(self, description):
        try:
            text = self.model_filter.generate_content(description).text.strip()
            return "FALSE" if "FALSE" in text else text
        except Exception as e:
            log(f"AI Filter Error: {e}", RED, "❌")
            return "FALSE"

    def markdown_to_html(self, text):
        text = text.replace("<", "&lt;").replace(">", "&gt;")
        text = re.sub(r'\*\*(.*?)\*\*', r'<b>\1</b>', text)
        text = text.replace('🏆 AI 甄选 (高性价比)：', '<b>🏆 AI 甄选 (高性价比)：</b>')
        text = text.replace('VPS：', '<b>VPS：</b>')
        text = text.replace('限时福利：', '<b>限时福利：</b>')
        text = text.replace('基础设施：', '<b>基础设施：</b>')
        text = text.replace('支付方式：', '<b>支付方式：</b>')
        text = text.replace('\n', '<br>')
        return text

    # --- Thread Logic ---
    def handle_thread(self, thread_data, extracted_links):
        try:
            self.threads_collection.insert_one(thread_data)
            now_sh = datetime.now(SHANGHAI)
            pub_date_sh = thread_data['pub_date'].astimezone(SHANGHAI)

            if (now_sh - pub_date_sh).total_seconds() <= 86400:
                log(f"Gemini 正在摘要: {thread_data['title'][:20]}...", YELLOW, "🤖")
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
                model_name = self.config.get('model', 'Unknown')
                
                msg_content = (
                    f"<h4 style='color:#2E8B57;margin-bottom:5px;margin-top:0;'>{thread_data['title']}</h4>"
                    f"<div style='font-size:12px;color:#666;margin-bottom:10px;'>"
                    f"👤 Author: {thread_data['creator']} <span style='margin:0 5px;color:#ddd;'>|</span> 🕒 {time_str} (SH) <span style='margin:0 5px;color:#ddd;'>|</span> 🤖 {model_name}"
                    f"</div><div style='font-size:14px;line-height:1.6;color:#333;'>{html_summary}</div>"
                    f"<div style='margin-top:20px;border-top:1px solid #eee;padding-top:10px;'><a href='{thread_data['link']}' style='display:inline-block;padding:8px 15px;background:#2E8B57;color:white;text-decoration:none;border-radius:4px;font-weight:bold;'>👉 查看原帖 (Source)</a></div>"
                )
                
                # 发送并验证
                push_title = f"LET新促销: {thread_data['title']}"
                if self.notifier.send_html_message(push_title, msg_content):
                    self.log_push_history("thread", thread_data['title'], thread_data['link'])

            return True 
        except errors.DuplicateKeyError: return False
        except: return False

    def handle_comment(self, comment_data, thread_data, created_at_sh):
        try:
            self.comments_collection.insert_one(comment_data)
            log(f"   ✅ [新回复] {comment_data['author']} (活跃中...)", GREEN)
            ai_resp = self.get_filter_from_ai(comment_data['message'])
            if "FALSE" not in ai_resp:
                log(f"      🚀 关键词匹配! 推送中...", GREEN)
                time_str = created_at_sh.strftime('%Y-%m-%d %H:%M')
                model_name = self.config.get('model', 'Unknown')
                
                # 动态标题：[Provider] 楼主新回复
                provider_name = thread_data.get('creator', 'Unknown')
                push_title = f"[{provider_name}] 楼主新回复"

                msg_content = (
                    f"<h4 style='color:#007bff;margin-bottom:5px;'>💬 {push_title}</h4>"
                    f"<div style='font-size:12px;color:#666;margin-bottom:10px;'>"
                    f"📌 Source: {thread_data['title']} <span style='margin:0 5px;color:#ddd;'>|</span> 🕒 {time_str} (SH) <span style='margin:0 5px;color:#ddd;'>|</span> 🤖 {model_name}"
                    f"</div>"
                    f"<div style='background:#f8f9fa;padding:10px;border:1px solid #eee;border-radius:5px;color:#333;'><b>🤖 AI 分析:</b><br>{ai_resp}</div>"
                    f"<div style='margin-top:15px;'><a href='{comment_data['url']}' style='color:#007bff;'>👉 查看回复</a></div>"
                )
                
                if self.notifier.send_html_message(push_title, msg_content):
                    self.log_push_history("reply", f"{provider_name}: {thread_data['title']}", comment_data['url'])
                    
        except errors.DuplicateKeyError: pass 
        except: pass

    # --- Scanning Logic ---
    def parse_let_comment(self, html_content, thread_data):
        soup = BeautifulSoup(html_content, 'html.parser')
        comments = soup.find_all('li', class_='ItemComment')
        now_sh = datetime.now(SHANGHAI)
        found_recent = False

        for comment in comments:
            try:
                date_str = comment.find('time')['datetime']
                created_at_aware = datetime.strptime(date_str, "%Y-%m-%dT%H:%M:%S%z")
                created_at_sh = created_at_aware.astimezone(SHANGHAI)
                
                if (now_sh - created_at_sh).total_seconds() > 86400: continue 
                found_recent = True
                
                author_tag = comment.find('a', class_='Username')
                if not author_tag or author_tag.text != thread_data['creator']: continue 
                
                comment_id = comment['id'].replace('Comment_', '')
                message = comment.find('div', class_='Message').text.strip()
                
                c_data = {
                    'comment_id': comment_id, 'thread_link': thread_data['link'],
                    'author': author_tag.text, 'message': message, 'created_at': created_at_aware, 
                    'url': f"{thread_data['link']}#Comment_{comment_id}"
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

        # Optimized Timeout to 15s
        REQ_TIMEOUT = 15

        try:
            time.sleep(1 if silent else 0.2)
            resp = self.scraper.get(thread_data['link'], timeout=REQ_TIMEOUT)
            if resp.status_code != 200: return False
            
            soup = BeautifulSoup(resp.text, 'html.parser')
            max_page = self.get_max_page_from_soup(soup)
            
            # Reverse Scan: Max -> 1
            for page in range(max_page, 0, -1):
                page_start = time.time()
                
                if page == 1 and max_page == 1:
                    content = resp.text
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

                if not has_recent:
                    break
            return True

        except Exception as e: return False

    # --- RSS Logic (Multi-Threaded) ---
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
            max_w = self.config.get('max_workers', 5)
            
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

    # --- Category Logic (Single-Threaded for Safety) ---
    def check_category_list(self):
        url = "https://lowendtalk.com/categories/offers"
        log("列表页扫描开始 (Category List)...", MAGENTA, "🔎")
        start_t = time.time()
        
        try:
            resp = self.scraper.get(url, timeout=30)
            if resp.status_code != 200: 
                log(f"   ❌ 过盾失败 (Status: {resp.status_code})", RED)
                return
            else:
                log(f"   🛡️ 过盾检测: 通过 (200 OK)", GREEN)

            soup = BeautifulSoup(resp.text, 'html.parser')
            
            # Universal Selector
            discussions = soup.select('.ItemDiscussion')
            if not discussions: discussions = soup.find_all('li', class_='Discussion')
            if not discussions: discussions = soup.select('tr.ItemDiscussion')
            
            total_count = len(discussions)
            log(f"   📜 解析到 {total_count} 个主题，正在筛选...", GRAY)
            
            candidates = []
            skipped_rss = 0
            skipped_time = 0
            
            for d in discussions:
                try:
                    a_tag = d.select_one('.DiscussionName a') or d.find('h3', class_='DiscussionName').find('a')
                    if not a_tag: continue
                    
                    link = a_tag['href']
                    if not link.startswith('http'): link = "https://lowendtalk.com" + link
                    title = a_tag.get_text(strip=True)
                    
                    if link in self.processed_urls_this_cycle: 
                        skipped_rss += 1
                        continue
                    
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
                            else: skipped_time += 1
                except: continue

            log(f"   ⚡ 筛选完成 | 命中候选: {len(candidates)} 个 (RSS跳过:{skipped_rss}/过期:{skipped_time})", GRAY)

            if candidates:
                log(f"   ⚠️ 启动深度抓取 (单线程)...", YELLOW)
                for t in candidates:
                    self.fetch_comments(t, silent=False)
                
            duration = time.time() - start_t
            log(f"列表页扫描完成 | 总耗时: {duration:.2f}s", MAGENTA)

        except Exception as e:
            log(f"Category Scan Error: {e}", RED, "❌")

    def start_monitoring(self):
        log("=== 监控服务启动 (AI Repush v6) ===", GREEN, "🚀")
        
        freq = self.config.get('frequency', 600)
        while True:
            cycle_start = time.time()
            self.processed_urls_this_cycle.clear()
            print(f"{GRAY}--------------------------------------------------{NC}")
            self.check_rss()
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

    msg_info "写入推送模块..."
    cat <<'EOF' > "$APP_DIR/send.py"
import json
import requests
import os
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
        self.token = ""
        self.session = requests.Session()
        self.session.headers.update({'User-Agent': 'curl/7.74.0'})
        adapter = HTTPAdapter(max_retries=Retry(total=3, backoff_factor=1))
        self.session.mount("https://", adapter)
        self.load_config()

    def load_config(self):
        try:
            with open(self.config_path, 'r') as f:
                self.token = json.load(f)['config'].get('pushplus_token', '')
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

    def send_html_message(self, title, html_content):
        if not self.token or self.token == "YOUR_PUSHPLUS_TOKEN_HERE":
            log(f"Virtual Push (Token missing)", RED, "⚠️")
            return False

        # FIX: Truncate title to meet Pushplus 100 char limit
        if len(title) > 95:
            title = title[:92] + "..."

        try:
            payload = {
                "token": self.token,
                "title": title,
                "content": html_content,
                "template": "html"
            }
            
            resp = self.session.post("https://www.pushplus.plus/send", json=payload, timeout=15)
            
            if resp.status_code == 200 and resp.json().get('code') == 200:
                log(f"Push Sent: {title[:30]}...", GREEN, "📨")
                self.record_success()
                return True 
            else:
                log(f"Push Fail: {resp.text}", RED, "❌")
                return False 
        except Exception as e:
            log(f"Push Error: {e}", RED, "❌")
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
    msg_info "=== 开始部署 ForumMonitor (Enhanced Edition) ==="
    
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
        read -p "请输入 Gemini API Key: " GK
        # UPDATE: 新安装时使用新的 Prompt
        local PROMPT="你是一个中文智能助手。请分析这条 VPS 优惠信息，**必须将所有内容（包括机房、配置）翻译为中文**。请筛选出 1-2 个性价比最高的套餐，并严格按照以下格式输出（不要代码块）：\n\n🏆 **AI 甄选 (高性价比)**：\n• **<套餐名>** (<价格>)：<简短推荐理由>\n\nVPS 列表：\n• **<套餐名>** → <价格> [ORDER_LINK_HERE]\n   └ <核心> / <内存> / <硬盘> / <带宽> / <流量>\n(注意：请在**每一个**识别到的套餐价格后面都加上 [ORDER_LINK_HERE] 占位符。)\n\n限时福利：\n• <优惠码/折扣/活动截止时间>\n\n基础设施：\n• <机房位置> | <IP类型> | <网络特点>\n\n支付方式：\n• <支付手段>\n\n🟢 优点: <简短概括>\n🔴 缺点: <简短概括>\n🎯 适合: <适用人群>"
        
        jq -n --arg pt "$PT" --arg gk "$GK" --arg prompt "$PROMPT" \
           '{config: {pushplus_token: $pt, gemini_api_key: $gk, model: "gemini-2.5-flash-lite", thread_prompt: $prompt, filter_prompt: "内容：XXX", frequency: 600}}' > "$CONFIG_FILE"
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
    printf "  %-4s %-12s %b%s%b\n" "3." "update" "$GRAY" "更新脚本" "$NC"
    
    echo -e "${CYAN} [服务控制]${NC}"
    printf "  %-4s %-12s %b%s%b\n" "4." "start" "$GRAY" "启动服务" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "5." "stop" "$GRAY" "停止服务" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "6." "restart" "$GRAY" "重启服务" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "7." "keepalive" "$GRAY" "开启保活" "$NC"

    echo -e "${CYAN} [配置与监控]${NC}"
    printf "  %-4s %-12s %b%s%b\n" "8." "edit" "$GRAY" "修改密钥/模型" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "9." "frequency" "$GRAY" "调整频率" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "10." "threads" "$GRAY" "修改线程数" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "11." "status" "$GRAY" "详细状态" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "12." "logs" "$GRAY" "实时日志" "$NC"

    echo -e "${CYAN} [功能测试]${NC}"
    printf "  %-4s %-12s %b%s%b\n" "13." "test-ai" "$GRAY" "测试 AI 连通性" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "14." "test-push" "$GRAY" "测试消息推送" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "15." "history" "$GRAY" "查看推送历史" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "16." "repush" "$GRAY" "手动推送活跃帖" "$NC"

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
            keepalive|7) run_setup_keepalive ;;
            edit|8) run_edit_config ;;
            frequency|9) run_edit_frequency ;;
            threads|10) run_edit_threads ;;
            status|11) run_status ;;
            logs|12) run_logs ;;
            test-ai|13) run_test_ai ;;
            test-push|14) run_test_push ;;
            history|15) run_view_history; read -n 1 -s -r -p "完成..." ;;
            repush|16) run_repush_active; read -n 1 -s -r -p "完成..." ;;
            update|3) run_update ;; 
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
            3) run_update ;;
            4) run_start; read -n 1 -s -r -p "完成..." ;;
            5) run_stop; read -n 1 -s -r -p "完成..." ;;
            6) run_restart; read -n 1 -s -r -p "完成..." ;;
            7) run_setup_keepalive; read -n 1 -s -r -p "完成..." ;;
            8) run_edit_config; read -n 1 -s -r -p "完成..." ;;
            9) run_edit_frequency; read -n 1 -s -r -p "完成..." ;;
            10) run_edit_threads; read -n 1 -s -r -p "完成..." ;;
            11) run_status; read -n 1 -s -r -p "完成..." ;;
            12) run_logs; read -n 1 -s -r -p "完成..." ;;
            13) run_test_ai; read -n 1 -s -r -p "完成..." ;;
            14) run_test_push; read -n 1 -s -r -p "完成..." ;;
            15) run_view_history; read -n 1 -s -r -p "按任意键返回..." ;;
            16) run_repush_active; read -n 1 -s -r -p "按任意键返回..." ;;
            q|Q) break ;;
            *) ;;
        esac
    done
}

main "$@"
