#!/bin/bash

# --- ForumMonitor 管理脚本 (排版优化版) ---
# Environment: Debian 11/12
# Features: Gemini 2.5 Pro, MongoDB, Pushplus, Systemd, Layout Fix
#
# Commands:
#   1. install    安装/重装服务 (会应用代码修复)
#   2. uninstall  卸载服务
#   3. update     更新脚本
#   4. start      启动服务
#   5. stop       停止服务
#   6. restart    重启服务
#   7. keepalive  设置保活任务
#   8. edit       修改配置 (Key/Model)
#   9. frequency  修改频率
#  10. status     查看状态
#  11. logs       查看日志
#  12. test-ai    测试 AI 连通性
#  13. test-push  测试消息推送
#
# --- (c) 2025 - Layout Fixed Edition ---

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

# 必须以 Root 运行
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
    [ -f "$CONFIG_FILE" ] && CUR_MODEL=$(jq -r '.config.model // "gemini-2.5-pro"' "$CONFIG_FILE")

    echo -e "${BLUE}================================================================${NC}"
    echo -e " ${CYAN}ForumMonitor 管理面板 (Layout Optimized)${NC}"
    echo -e "${BLUE}================================================================${NC}"
    printf " %-16s %b%-20s%b | %-16s %b%-10s%b\n" "运行状态:" "$STATUS_COLOR" "$STATUS_TEXT" "$NC" "已推送通知:" "$GREEN" "$PUSH_COUNT" "$NC"
    printf " %-16s %b%-20s%b | %-16s %b%-10s%b\n" "运行持续:" "$YELLOW" "$UPTIME" "$NC" "自动重启:" "$RED" "$RESTART_COUNT 次" "$NC"
    printf " %-16s %b%-20s%b | %-16s %b%-10s%b\n" "当前模型:" "$CYAN" "$CUR_MODEL" "$NC" " " "" "" ""
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
    local C_MODEL=$(jq -r '.config.model // "gemini-2.5-pro"' "$CONFIG_FILE")

    read -p "Pushplus Token (当前: ***${C_PT: -6}): " N_PT
    read -p "Gemini API Key (当前: ***${C_GK: -6}): " N_GK
    echo -e "${YELLOW}提示: 推荐 gemini-2.5-pro, gemini-1.5-flash 或 gemini-1.5-pro${NC}"
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

# --- 测试功能 ---

run_test_push() {
    check_service_exists
    check_jq
    msg_info "正在发送全格式测试通知..."
    
    local TITLE="TEST: LET新促销: [测试] Gemini 2.5 Pro 模拟推送"
    local CUR_TIME=$(date "+%Y-%m-%d %H:%M")
    local MODEL=$(jq -r '.config.model // "gemini-2.5-pro"' "$CONFIG_FILE")
    
    # 这里的测试内容模拟新的排版格式
    local CONTENT="<h4 style='color:#2E8B57;margin-bottom:5px;margin-top:0;'>📢 [TEST] Example VPS Offer</h4><div style='font-size:12px;color:#666;margin-bottom:10px;'>👤 Author: Admin <span style='margin:0 5px;color:#ddd;'>|</span> 🕒 $CUR_TIME (SH) <span style='margin:0 5px;color:#ddd;'>|</span> 🧠 $MODEL</div><div style='font-size:14px;line-height:1.6;color:#333;'><b>VPS：</b><br>• <b>Example Plan</b> → \$5.00/mo <a href='https://google.com' style='color:#007bff;font-weight:bold;'>[下单地址]</a><br>&nbsp;&nbsp;&nbsp;└ 2C / 4G / 60G SSD / 1Gbps<br><br><b>限时福利：</b><br>• 优惠码 TEST_CODE 享终身 5 折。<br><br><b>基础设施：</b><br>• 洛杉矶 (LA) | CN2 GIA | 1 IPv4 + /64 IPv6<br><br><b>支付方式：</b><br>• PayPal, Alipay, Crypto<br><br>🟢 优点: 线路优质，价格低廉。<br>🔴 缺点: 流量较少，不仅工单。<br>🎯 适合: 建站与个人学习用户。</div><div style='margin-top:20px;border-top:1px solid #eee;padding-top:10px;'><a href='https://google.com' style='display:inline-block;padding:8px 15px;background:#2E8B57;color:white;text-decoration:none;border-radius:4px;font-weight:bold;'>👉 查看原帖 (Source)</a></div>"
    
    local PY_COMMAND="import sys; sys.path.append('$APP_DIR'); from send import NotificationSender; sender=NotificationSender('$CONFIG_FILE'); sender.send_html_message('$TITLE', \"\"\"$CONTENT\"\"\")"
    
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
    
    # 允许 3 分钟的宽限期
    if [ "$DIFF" -gt "$(($FREQ + 180))" ]; then
        echo "$(date): [Watchdog] 服务僵死 (${DIFF}s 未响应). 正在重启..."
        echo "$(date '+%Y-%m-%d %H:%M:%S')" >> "$RESTART_LOG_FILE"
        systemctl restart $SERVICE_NAME
    fi
}

run_setup_keepalive() {
    msg_info "配置 Crontab 保活任务..."
    local CMD="*/5 * * * * $(realpath "$0") monitor >> $APP_DIR/monitor.log 2>&1"
    
    # 幂等添加
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

# 辅助: 更新配置中的 Prompt (不覆盖 Key)
run_update_config_prompt() {
    if [ -f "$CONFIG_FILE" ]; then
        # UPDATE: 使用了新的双行排版 Prompt
        local NEW_THREAD_PROMPT="你是一个中文智能助手。请分析这条 VPS 优惠信息，**必须将所有内容（包括机房、配置）翻译为中文**。请严格按照以下格式输出（不要代码块）：\n\nVPS：\n• **<套餐名>** → <价格> [ORDER_LINK_HERE]\n   └ <核心> / <内存> / <硬盘> / <带宽> / <流量>\n(请将占位符 [ORDER_LINK_HERE] 放置在第一个套餐的价格后面。如果有多个套餐，请换行列出，但无需再添加占位符)\n\n限时福利：\n• <优惠码/折扣/活动截止时间>\n\n基础设施：\n• <机房位置> | <IP类型> | <网络特点>\n\n支付方式：\n• <支付手段>\n\n🟢 优点: <简短概括>\n🔴 缺点: <简短概括>\n🎯 适合: <适用人群>"
        local NEW_FILTER_PROMPT="你是一个中文辅助助手。请用**中文**简要总结这条回复的内容。如果回复内容是无意义的（如纯表情、'谢谢'、'已买'、'顶贴'、'Up'）或与VPS服务无关，请直接回复 FALSE。否则，请输出简短的中文摘要。"

        jq --arg p "$NEW_THREAD_PROMPT" --arg f "$NEW_FILTER_PROMPT" \
           '.config.thread_prompt = $p | .config.filter_prompt = $f' \
           "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    fi
}

# --- 核心代码写入 (Python) ---
# 包含：Gemini 2.5 Pro 支持, Title 前缀, Test 前缀, Model 显示
# FIX: 修复了 handle_thread 中链接注入的顺序，防止 HTML 被转义
_write_python_files_and_deps() {
    msg_info "写入 Python 核心代码 (With Fixes)..."
    
    cat <<'EOF' > "$APP_DIR/$PYTHON_SCRIPT_NAME"
import json
import time
import requests
from bs4 import BeautifulSoup
from datetime import datetime, timedelta, timezone
from send import NotificationSender
import os
from pymongo import MongoClient
import shutil
import sys
import re
import google.generativeai as genai

# Python 日志颜色定义
GREEN = '\033[0;32m'
YELLOW = '\033[0;33m'
RED = '\033[0;31m'
CYAN = '\033[0;36m'
BLUE = '\033[0;34m'
NC = '\033[0m'
GRAY = '\033[0;90m'
WHITE = '\033[1;37m'

# Define Shanghai Timezone (UTC+8)
SHANGHAI = timezone(timedelta(hours=8))

def log(msg, color=NC, icon=""):
    timestamp = datetime.now(SHANGHAI).strftime("%H:%M:%S")
    prefix = f"{icon} " if icon else ""
    print(f"{GRAY}[{timestamp}]{NC} {color}{prefix}{msg}{NC}")

class ForumMonitor:
    def __init__(self, config_path='data/config.json'):
        self.config_path = config_path
        self.mongo_host = os.getenv("MONGO_HOST", 'mongodb://localhost:27017/')
        self.load_config()

        self.mongo_client = MongoClient(self.mongo_host) 
        self.db = self.mongo_client['forum_monitor']
        self.threads_collection = self.db['threads']
        self.comments_collection = self.db['comments']
        
        # Scraper init (Standard requests)
        self.scraper = requests.Session()
        self.scraper.headers.update({
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
            'Accept-Language': 'en-US,en;q=0.9'
        })

        # Gemini Init
        try:
            api_key = self.config.get('gemini_api_key')
            model_name = self.config.get('model', 'gemini-2.5-pro')
            if not api_key:
                log("Gemini API Key missing in config!", RED, "❌")
            else:
                genai.configure(api_key=api_key)
                # Model for Threads
                self.model_summary = genai.GenerativeModel(
                    model_name,
                    system_instruction=self.config.get('thread_prompt', '')
                )
                # Model for Comments/Filter
                self.model_filter = genai.GenerativeModel(
                    model_name,
                    system_instruction=self.config.get('filter_prompt', '')
                )
                log(f"Gemini Loaded ({model_name})", GREEN, "🧠")
        except Exception as e:
            log(f"Gemini Init Failed: {e}", RED, "❌")

        try:
            self.threads_collection.create_index('link', unique=True)
            self.comments_collection.create_index('comment_id', unique=True)
        except Exception: pass

    def load_config(self):
        try:
            if not os.path.exists(self.config_path):
                shutil.copy('example.json', self.config_path)
            with open(self.config_path, 'r') as f:
                self.config = json.load(f)['config']
                self.notifier = NotificationSender(self.config_path)
            log(f"Config loaded.", GREEN, "⚙️")
        except Exception as e:
            log(f"Config Error: {e}", RED, "❌")
            self.config = {}

    def update_heartbeat(self):
        try:
            with open('data/heartbeat.txt', 'w') as f:
                f.write(str(int(time.time())))
        except: pass

    def get_summarize_from_ai(self, description):
        try:
            # 使用 Gemini 生成内容
            response = self.model_summary.generate_content(description)
            return response.text
        except Exception as e:
            log(f"Gemini Summary Error: {e}", RED, "⚠️")
            return "AI 摘要生成失败。"

    def get_filter_from_ai(self, description):
        try:
            response = self.model_filter.generate_content(description)
            text = response.text.strip()
            # 兼容旧逻辑，如果是 FALSE 则返回 FALSE
            if "FALSE" in text: return "FALSE"
            return text
        except Exception as e:
            log(f"Gemini Filter Error: {e}", RED, "⚠️")
            # 如果出错 (如404)，为了防止日志爆炸，可以打印可用模型列表
            if "404" in str(e):
               log(f"Model Not Found. Please check 'fm 8' to set a valid model.", YELLOW)
               try:
                   log("Available Models:", YELLOW)
                   for m in genai.list_models():
                       if 'generateContent' in m.supported_generation_methods:
                           print(f" - {m.name}")
               except: pass
            return "FALSE"

    def markdown_to_html(self, text):
        text = text.replace("<", "&lt;").replace(">", "&gt;")
        text = re.sub(r'\*\*(.*?)\*\*', r'<b>\1</b>', text)
        text = text.replace('VPS：', '<b>VPS：</b>')
        text = text.replace('限时福利：', '<b>限时福利：</b>')
        text = text.replace('基础设施：', '<b>基础设施：</b>')
        text = text.replace('支付方式：', '<b>支付方式：</b>')
        text = text.replace('\n', '<br>')
        return text

    def handle_thread(self, thread_data, extracted_links):
        existing_thread = self.threads_collection.find_one({'link': thread_data['link']})
        if not existing_thread:
            self.threads_collection.insert_one(thread_data)
            log(f"{WHITE}@{thread_data['creator']} {CYAN}{thread_data['title']}{NC}\n           {GRAY}└─ {thread_data['link']}", GREEN, "🟢")
            
            now_sh = datetime.now(SHANGHAI)
            pub_date_sh = thread_data['pub_date'].astimezone(SHANGHAI)

            if (now_sh - pub_date_sh).total_seconds() <= 86400:
                log(f"Gemini 正在摘要...", YELLOW, "🤖")
                raw_summary = self.get_summarize_from_ai(thread_data['description'])
                
                # --- FIX: 先转 HTML，再插入链接，防止链接标签被转义 ---
                html_summary = self.markdown_to_html(raw_summary)
                
                if extracted_links:
                    link_html = f' <a href="{extracted_links[0]}" style="color:#007bff;font-weight:bold;">[下单地址]</a>'
                    # 将占位符替换为真实链接 (注意：这里替换的是 html_summary)
                    html_summary = html_summary.replace("[ORDER_LINK_HERE]", link_html, 1)
                # ---------------------------------------------------

                time_str = pub_date_sh.strftime('%Y-%m-%d %H:%M')
                
                model_name = self.config.get('model', 'Unknown')
                
                # 更新标题，增加前缀
                notification_title = f"LET新促销: {thread_data['title']}"

                msg_content = (
                    f"<h4 style='color:#2E8B57;margin-bottom:5px;margin-top:0;'>{thread_data['title']}</h4>"
                    f"<div style='font-size:12px;color:#666;margin-bottom:10px;'>"
                    f"👤 Author: {thread_data['creator']} <span style='margin:0 5px;color:#ddd;'>|</span> 🕒 {time_str} (SH) <span style='margin:0 5px;color:#ddd;'>|</span> 🧠 {model_name}"
                    f"</div>"
                    f"<div style='font-size:14px;line-height:1.6;color:#333;'>"
                    f"{html_summary}"
                    f"</div>"
                    f"<div style='margin-top:20px;border-top:1px solid #eee;padding-top:10px;'><a href='{thread_data['link']}' style='display:inline-block;padding:8px 15px;background:#2E8B57;color:white;text-decoration:none;border-radius:4px;font-weight:bold;'>👉 查看原帖 (Source)</a></div>"
                )
                self.notifier.send_html_message(notification_title, msg_content)
            return True 
        return False 

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

    def parse_let_comment(self, html_content, thread_data):
        soup = BeautifulSoup(html_content, 'html.parser')
        comments = soup.find_all('li', class_='ItemComment')
        
        now_sh = datetime.now(SHANGHAI)

        for comment in comments:
            try:
                date_str = comment.find('time')['datetime']
                created_at_aware = datetime.strptime(date_str, "%Y-%m-%dT%H:%M:%S%z")
                created_at_sh = created_at_aware.astimezone(SHANGHAI)
                
                if (now_sh - created_at_sh).total_seconds() > 86400:
                    continue 

                author = comment.find('a', class_='Username').text
                if author != thread_data['creator']: continue 
                
                comment_id = comment['id'].replace('Comment_', '')
                message = comment.find('div', class_='Message').text.strip()
                
                c_data = {
                    'comment_id': comment_id, 'thread_link': thread_data['link'],
                    'author': author, 'message': message, 'created_at': created_at_aware, 
                    'url': f"{thread_data['link']}#Comment_{comment_id}"
                }
                self.handle_comment(c_data, thread_data, created_at_sh)
            except: pass

    def fetch_comments(self, thread_data, silent=False):
        thread_info = self.threads_collection.find_one({'link': thread_data['link']})
        try: last_page = int(thread_info.get('last_page', 1))
        except: last_page = 1
        if last_page < 1: last_page = 1

        while True:
            page_url = f"{thread_data['link']})/p{last_page}"
            try:
                time.sleep(1) 
                resp = self.scraper.get(page_url, timeout=20)
                
                if resp.status_code == 200:
                    soup = BeautifulSoup(resp.text, 'html.parser')
                    max_page = self.get_max_page_from_soup(soup)
                    
                    if not silent:
                        log(f"   📄 [进度] 第 {last_page} 页 / 共 {max_page} 页", GRAY)

                    self.parse_let_comment(resp.text, thread_data)
                    
                    if last_page < max_page:
                        last_page += 1
                    else:
                        self.threads_collection.update_one({'link': thread_data['link']}, {'$set': {'last_page': max_page}})
                        break
                else:
                    break 
            except Exception:
                break

    def handle_comment(self, comment_data, thread_data, created_at_sh):
        if not self.comments_collection.find_one({'comment_id': comment_data['comment_id']}):
            self.comments_collection.update_one({'comment_id': comment_data['comment_id']}, {'$set': comment_data}, upsert=True)
            
            log(f"   ✅ [新回复] {comment_data['author']} (活跃中...)", GREEN)
            
            ai_resp = self.get_filter_from_ai(comment_data['message'])
            if "FALSE" not in ai_resp:
                log(f"      🚀 关键词匹配! 推送中...", GREEN)
                
                time_str = created_at_sh.strftime('%Y-%m-%d %H:%M')
                model_name = self.config.get('model', 'Unknown')

                msg_content = (
                    f"<h4 style='color:#007bff;margin-bottom:5px;'>💬 楼主新回复</h4>"
                    f"<div style='font-size:12px;color:#666;margin-bottom:10px;'>"
                    f"📌 Source: {thread_data['title']} <span style='margin:0 5px;color:#ddd;'>|</span> 🕒 {time_str} (SH) <span style='margin:0 5px;color:#ddd;'>|</span> 🤖 {model_name}"
                    f"</div>"
                    f"<div style='background:#f8f9fa;padding:10px;border:1px solid #eee;border-radius:5px;color:#333;'><b>🤖 AI 分析:</b><br>{ai_resp}</div>"
                    f"<div style='margin-top:15px;'><a href='{comment_data['url']}' style='color:#007bff;'>👉 查看回复</a></div>"
                )
                self.notifier.send_html_message("楼主新回复提醒", msg_content)

    def check_let(self, url="https://lowendtalk.com/categories/offers/feed.rss"):
        try:
            resp = self.scraper.get(url, timeout=30)
            if resp.status_code == 200: self.parse_let(resp.text)
        except Exception as e: log(f"RSS Error: {e}", RED, "❌")

    def html_to_text_with_links(self, html_content):
        soup = BeautifulSoup(html_content, 'html.parser')
        for a in soup.find_all('a', href=True):
            markdown_link = f" [{a.get_text(strip=True)}]({a['href']}) "
            a.replace_with(markdown_link)
        return soup.get_text(separator=" ", strip=True)

    def parse_let(self, rss_feed):
        soup = BeautifulSoup(rss_feed, 'xml')
        items = soup.find_all('item')
        new_count = 0
        for item in items:
            try:
                raw_description_html = item.find('description').text
                desc_soup = BeautifulSoup(raw_description_html, 'html.parser')
                extracted_links = []
                for a in desc_soup.find_all('a', href=True):
                    href = a['href']
                    if href.startswith('http') and 'lowendtalk.com' not in href and href not in extracted_links:
                        extracted_links.append(href)
                processed_description = self.html_to_text_with_links(raw_description_html)
                
                link = item.find('link').text
                pub_date_str = item.find('pubDate').text
                pub_date_aware = datetime.strptime(pub_date_str, "%a, %d %b %Y %H:%M:%S %z")
                
                t_data = {
                    'cate': 'let', 'title': item.find('title').text, 'link': link,
                    'description': processed_description,
                    'pub_date': pub_date_aware, 
                    'created_at': datetime.utcnow(), 'creator': item.find('dc:creator').text, 'last_page': 1
                }

                now_sh = datetime.now(SHANGHAI)
                pub_date_sh = pub_date_aware.astimezone(SHANGHAI)
                thread_age = (now_sh - pub_date_sh).total_seconds()

                is_known_thread = self.threads_collection.find_one({'link': link})

                if is_known_thread:
                    if thread_age <= 86400:
                        log(f"{WHITE}@{t_data['creator']} {CYAN}{t_data['title']}{NC}\n           {GRAY}└─ {link}", CYAN, "🔎")
                        self.fetch_comments(t_data, silent=False)
                    else:
                        self.fetch_comments(t_data, silent=True)
                else:
                    if thread_age > 86400:
                        self.threads_collection.insert_one(t_data) 
                        self.fetch_comments(t_data, silent=True)
                    else:
                        is_new = self.handle_thread(t_data, extracted_links)
                        if is_new: new_count += 1
                        self.fetch_comments(t_data, silent=False)

            except Exception as e: pass
        if new_count == 0: log(f"完成。无新内容。", GRAY, "✅")

    def start_monitoring(self):
        log("=== 监控服务启动 (Gemini 2.5 Pro) ===", GREEN, "🚀")
        freq = self.config.get('frequency', 600)
        while True:
            print(f"{GRAY}--------------------------------------------------{NC}")
            log(f"正在扫描 LET...", BLUE, "🔄")
            try:
                self.check_let()
            except Exception as e: log(f"循环错误: {e}", RED, "❌")
            self.update_heartbeat()
            log(f"休眠 {freq}秒...", GRAY, "😴")
            time.sleep(freq)

if __name__ == "__main__":
    sys.stdout.reconfigure(line_buffering=True)
    ForumMonitor().start_monitoring()
EOF

    cat <<EOF > "$APP_DIR/requirements.txt"
requests
beautifulsoup4
pymongo
urllib3<2.0
lxml
google-generativeai
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
        self.send_html_message("ForumMonitor Notification", message)

    def send_html_message(self, title, html_content):
        if not self.token or self.token == "YOUR_PUSHPLUS_TOKEN_HERE":
            log(f"Virtual Push (Token missing)", RED, "⚠️")
            return

        try:
            payload = {
                "token": self.token,
                "title": title,
                "content": html_content,
                "template": "html"
            }
            
            resp = self.session.post("https://www.pushplus.plus/send", json=payload, timeout=15)
            
            if resp.json().get('code') == 200:
                log(f"Push Sent: {title[:30]}...", GREEN, "📨")
                self.record_success()
            else:
                log(f"Push Fail: {resp.text}", RED, "❌")
        except Exception as e:
            log(f"Push Error: {e}", RED, "❌")
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
    msg_info "=== 开始部署 ForumMonitor (Gemini Edition) ==="
    
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
        # UPDATE: 新安装时使用双行排版 Prompt
        local PROMPT="你是一个中文智能助手。请分析这条 VPS 优惠信息，**必须将所有内容（包括机房、配置）翻译为中文**。请严格按照以下格式输出（不要代码块）：\n\nVPS：\n• **<套餐名>** → <价格> [ORDER_LINK_HERE]\n   └ <核心> / <内存> / <硬盘> / <带宽> / <流量>\n(请将占位符 [ORDER_LINK_HERE] 放置在第一个套餐的价格后面。如果有多个套餐，请换行列出，但无需再添加占位符)\n\n限时福利：\n• <优惠码/折扣/活动截止时间>\n\n基础设施：\n• <机房位置> | <IP类型> | <网络特点>\n\n支付方式：\n• <支付手段>\n\n🟢 优点: <简短概括>\n🔴 缺点: <简短概括>\n🎯 适合: <适用人群>"
        
        jq -n --arg pt "$PT" --arg gk "$GK" --arg prompt "$PROMPT" \
           '{config: {pushplus_token: $pt, gemini_api_key: $gk, model: "gemini-2.5-pro", thread_prompt: $prompt, filter_prompt: "内容：XXX", frequency: 600}}' > "$CONFIG_FILE"
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
    printf "  %-4s %-12s %b%s%b\n" "10." "status" "$GRAY" "详细状态" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "11." "logs" "$GRAY" "实时日志" "$NC"

    echo -e "${CYAN} [功能测试]${NC}"
    printf "  %-4s %-12s %b%s%b\n" "12." "test-ai" "$GRAY" "测试 AI 连通性" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "13." "test-push" "$GRAY" "测试消息推送" "$NC"

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
            status|10) run_status ;;
            logs|11) run_logs ;;
            test-ai|12) run_test_ai ;;
            test-push|13) run_test_push ;;
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
            10) run_status; read -n 1 -s -r -p "完成..." ;;
            11) run_logs; read -n 1 -s -r -p "完成..." ;;
            12) run_test_ai; read -n 1 -s -r -p "完成..." ;;
            13) run_test_push; read -n 1 -s -r -p "完成..." ;;
            q|Q) break ;;
            *) ;;
        esac
    done
}

main "$@"
