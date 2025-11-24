#!/bin/bash

# --- 此脚本用于在 Debian 11/12 上管理 ForumMonitor 服务 ---
#
# Commands:
#   1. install    (默认) 安装/重装服务 (Mongo, Python, systemd)。
#   2. uninstall  完全移除服务、依赖和数据。
#   3. update     从 GitHub 更新此管理脚本。
#   4. start      启动服务。
#   5. stop       停止服务。
#   6. restart    重启服务。
#   7. keepalive  开启自动保活 (Crontab 自动检测并重启)。
#   8. edit       交互式地修改 API 密钥 (Pushplus, CF)。
#   9. frequency  修改脚本遍历时间 (秒)。
#  10. status     查看服务运行详细状态。
#  11. logs       查看脚本实时日志 (显示标题+作者)。
#  12. test-ai    测试 Cloudflare AI 连通性。
#  13. test-push  发送一条 Pushplus 测试消息。
#   q. quit       退出菜单。
#
# --- (c) 2025 - 自动生成 (V57 - 智能留存与防屏蔽版) ---

set -e
set -u

# --- 1. 定义全局配置变量 ---
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

# Bash 颜色定义 (用于菜单)
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# --- 2. 辅助功能 ---

check_service_exists() {
    if [ ! -f "$SYSTEMD_SERVICE_FILE" ]; then
        echo -e "${RED}错误: 服务 $SERVICE_NAME 未安装。${NC}"
        echo "请先运行 'fm 1' (安装)。"
        exit 1
    fi
}

check_jq() {
    if ! command -v jq &> /dev/null; then
        echo "--- 正在安装 jq (JSON 处理器)... ---"
        apt-get update -qq
        apt-get install -y jq > /dev/null
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
    if [ -f "$STATS_FILE" ]; then PUSH_COUNT=$(jq -r '.push_count // 0' "$STATS_FILE"); fi
    local RESTART_COUNT=0
    local LAST_RESTART="无"
    if [ -f "$RESTART_LOG_FILE" ]; then
        RESTART_COUNT=$(wc -l < "$RESTART_LOG_FILE")
        LAST_RESTART=$(tail -n 1 "$RESTART_LOG_FILE")
    fi

    echo -e "${BLUE}================================================================${NC}"
    echo -e " ${CYAN}ForumMonitor 实时状态仪表盘${NC}"
    echo -e "${BLUE}================================================================${NC}"
    printf " %-16s %b%-20s%b | %-16s %b%-10s%b\n" "运行状态:" "$STATUS_COLOR" "$STATUS_TEXT" "$NC" "已推送通知:" "$GREEN" "$PUSH_COUNT" "$NC"
    printf " %-16s %b%-20s%b | %-16s %b%-10s%b\n" "运行持续:" "$YELLOW" "$UPTIME" "$NC" "自动重启:" "$RED" "$RESTART_COUNT 次" "$NC"
    echo -e "${BLUE}================================================================${NC}"
}

# --- 3. 管理功能 ---

run_start() {
    check_service_exists
    echo "--- 正在启动 $SERVICE_NAME 服务... ---"
    systemctl start $SERVICE_NAME
    echo "服务已启动。"
}

run_stop() {
    check_service_exists
    echo "--- 正在停止 $SERVICE_NAME 服务... ---"
    systemctl stop $SERVICE_NAME
    echo "服务已停止。"
}

run_restart() {
    check_service_exists
    echo "--- 正在重启 $SERVICE_NAME 服务... ---"
    systemctl restart $SERVICE_NAME
    echo "服务已重启。"
}

run_edit_config() {
    check_service_exists
    check_jq
    echo "--- 交互式修改 API 密钥 (按 Enter 保留) ---"
    local C_PT=$(jq -r '.config.pushplus_token' "$CONFIG_FILE")
    local C_CT=$(jq -r '.config.cf_token' "$CONFIG_FILE")
    local C_CID=$(jq -r '.config.cf_account_id' "$CONFIG_FILE")

    read -p "Pushplus Token (当前: ***${C_PT: -6}): " N_PT
    read -p "Cloudflare API Token (当前: ***${C_CT: -6}): " N_CT
    read -p "Cloudflare Account ID (当前: $C_CID): " N_CID

    [ -z "$N_PT" ] && N_PT="$C_PT"
    [ -z "$N_CT" ] && N_CT="$C_CT"
    [ -z "$N_CID" ] && N_CID="$C_CID"

    jq --arg a "$N_PT" --arg b "$N_CT" --arg c "$N_CID" \
       '.config.pushplus_token=$a|.config.cf_token=$b|.config.cf_account_id=$c' \
       "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    echo "配置已更新。"
    run_restart
}

run_edit_frequency() {
    check_service_exists
    check_jq
    local CUR=$(jq -r '.config.frequency' "$CONFIG_FILE")
    echo "当前间隔: $CUR 秒"
    read -p "新间隔 (秒): " NEW
    if ! [[ "$NEW" =~ ^[0-9]+$ ]]; then echo -e "${RED}无效数字${NC}"; return 1; fi
    jq --argjson v "$NEW" '.config.frequency=$v' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    echo "频率已更新。"
    run_restart
}

run_status() {
    check_service_exists
    echo "--- 服务详情 ---"
    systemctl status $SERVICE_NAME --no-pager
    if [ -f "$HEARTBEAT_FILE" ]; then
        local DIFF=$(($(date +%s) - $(cat "$HEARTBEAT_FILE")))
        echo -e "\n--- 内部心跳 ---\n上次打卡: ${GREEN}$DIFF 秒前${NC}"
    fi
}

run_logs() {
    check_service_exists
    echo "--- 显示实时日志 (Ctrl+C 退出) ---"
    echo "提示: 正在使用 Raw Output 模式以强制显示颜色。"
    sleep 1
    journalctl -u $SERVICE_NAME -f -n 50 --output cat
}

run_test_push() {
    check_service_exists
    check_jq
    echo "--- 正在发送 V57 模拟通知 ---"
    
    local TITLE="[测试] Black Friday VPS Deals"
    local CUR_TIME=$(date "+%Y-%m-%d %H:%M")
    
    local CONTENT="<h3 style='color:#2E8B57;'>📢 [TEST] Black Friday VPS Deals</h3><div style='font-size:12px;color:#666;margin-bottom:10px;'>👤 作者: Admin <span style='margin:0 5px;color:#ddd;'>|</span> 🕒 $CUR_TIME (SH)</div><div style='border-left:4px solid #4CAF50;padding:8px;background:#f1f8e9;color:#333;margin-bottom:10px;'><b>🤖 AI 深度分析:</b><br><b>优点：</b>价格低廉，NVMe硬盘<br><b>缺点：</b>无工单支持<br><b>适合用途：</b>个人博客，代理<br><b>可用区域：</b>🇺🇸 洛杉矶, 🇩🇪 法兰克福<br><b>支付方式：</b>💳 支付宝, PayPal, USDT<br><b>合适套餐：</b>1C/1G 年付\$10款</div><div style='background:#f9f9f9;padding:10px;border-radius:5px;border:1px solid #eee;'><b style='color:#000;'>📦 精选套餐:</b><br>• 1C/1G/20G | <span style='color:#d9534f;font-weight:bold;'>\$10/yr</span> | <a href='#' style='color:#007bff;'>[下单]</a><br>• 2C/2G/40G | <span style='color:#d9534f;font-weight:bold;'>\$20/yr</span> | <a href='#' style='color:#007bff;'>[下单]</a></div><div style='margin-top:15px;'><a href='https://lowendtalk.com' style='display:inline-block;padding:8px 15px;background:#2E8B57;color:white;text-decoration:none;border-radius:4px;'>👉 查看原帖</a></div>"
    
    local PY_COMMAND="import sys; sys.path.append('$APP_DIR'); from send import NotificationSender; sender=NotificationSender('$CONFIG_FILE'); sender.send_html_message('$TITLE', \"\"\"$CONTENT\"\"\")"
    
    "$VENV_DIR/bin/python" -c "$PY_COMMAND"
}

run_test_ai() {
    check_service_exists
    check_jq
    echo "--- 测试 AI ---"
    local CMD="import sys; sys.path.append('$APP_DIR'); from core import ForumMonitor; print(ForumMonitor(config_path='$CONFIG_FILE').get_filter_from_ai(\"Test msg return FALSE\"))"
    set +e
    local RES=$("$VENV_DIR/bin/python" -c "$CMD")
    set -e
    echo "AI Response: $RES"
    [[ "$RES" == *"FALSE"* ]] && echo -e "${GREEN}AI 正常${NC}" || echo -e "${YELLOW}AI 异常${NC}"
}

run_update() {
    local P=$(realpath "$0")
    local T="${P}.new"
    echo "--- 下载更新... ---"
    if curl -s -L "$UPDATE_URL" -o "$T"; then
        if bash -n "$T"; then
            chmod +x "$T"; mv "$T" "$P"
            echo -e "${GREEN}更新成功! 应用中...${NC}"; sleep 2
            exec "$P" "--post-update"
        else
            echo -e "${RED}脚本校验失败${NC}"; rm -f "$T"
        fi
    else
        echo -e "${RED}下载失败${NC}"
    fi
}

run_monitor_logic() {
    check_jq
    if ! systemctl is-active --quiet $SERVICE_NAME; then return 0; fi
    if [ ! -f "$HEARTBEAT_FILE" ]; then return 0; fi
    local LAST=$(cat "$HEARTBEAT_FILE")
    local FREQ=$(jq -r '.config.frequency // 600' "$CONFIG_FILE")
    local DIFF=$(($(date +%s) - LAST))
    if [ "$DIFF" -gt "$(($FREQ + 180))" ]; then
        echo "$(date): [Alarm] Frozen for $DIFF s. Restarting..."
        echo "$(date '+%Y-%m-%d %H:%M:%S')" >> "$RESTART_LOG_FILE"
        systemctl restart $SERVICE_NAME
    fi
}

run_setup_keepalive() {
    echo "--- 设置保活 (Cron) ---"
    local CMD="*/5 * * * * $(realpath "$0") monitor >> $APP_DIR/monitor.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "monitor"; echo "$CMD") | crontab -
    echo -e "${GREEN}已添加保活任务${NC}"
}

run_uninstall() {
    echo "=== 卸载中... ==="
    crontab -l 2>/dev/null | grep -v "monitor" | crontab -
    systemctl stop $SERVICE_NAME mongod || true
    systemctl disable $SERVICE_NAME mongod || true
    rm -f "$SYSTEMD_SERVICE_FILE"
    systemctl daemon-reload
    rm -rf "$APP_DIR" "$SHORTCUT_PATH"
    echo "=== 完成 ==="
}

# V45: 更新 Prompt 增加可用区域和支付方式
run_update_config_prompt() {
    if [ -f "$CONFIG_FILE" ]; then
        local NEW_THREAD_PROMPT="你是一个中文智能助手。请分析这条 VPS 优惠信息，按以下格式输出分析：\n优点：xxx\n缺点：xxx\n适合用途：xxx\n可用区域：xxx\n支付方式：xxx\n合适套餐：(推荐一款)\n\n然后列出**所有**提到的 VPS 套餐。请**务必**将该套餐的购买链接(如有)放在对应行的末尾。格式：\n📦 套餐列表：\n- <配置> | <价格> | <优惠码> | [购买链接](URL)"
        jq --arg p "$NEW_THREAD_PROMPT" '.config.thread_prompt = $p' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    fi
}

_write_python_files_and_deps() {
    echo "--- 正在写入 Python 核心代码 (V57 Smart Retention) ---"
    cat <<'EOF' > "$APP_DIR/$PYTHON_SCRIPT_NAME"
import json
import time
import requests
from bs4 import BeautifulSoup
from datetime import datetime, timedelta
from send import NotificationSender
import os
from pymongo import MongoClient
import cfscrape
import shutil
import sys
import re

# Python 日志颜色定义
GREEN = '\033[0;32m'
YELLOW = '\033[0;33m'
RED = '\033[0;31m'
CYAN = '\033[0;36m'
BLUE = '\033[0;34m'
NC = '\033[0m'
GRAY = '\033[0;90m'

def log(msg, color=NC, icon=""):
    timestamp = datetime.now().strftime("%H:%M:%S")
    prefix = f"{icon} " if icon else ""
    print(f"{GRAY}[{timestamp}]{NC} {color}{prefix}{msg}{NC}")

class ForumMonitor:
    def __init__(self, config_path='data/config.json'):
        self.config_path = config_path
        self.proxy_host = os.getenv("PROXY_HOST", None)
        self.mongo_host = os.getenv("MONGO_HOST", 'mongodb://localhost:27017/')
        self.load_config()

        self.mongo_client = MongoClient(self.mongo_host) 
        self.db = self.mongo_client['forum_monitor']
        self.threads_collection = self.db['threads']
        self.comments_collection = self.db['comments']
        
        try:
            self.scraper = cfscrape.create_scraper()
        except Exception as e:
            log(f"Scraper Init Failed: {e}", RED, "❌")
            self.scraper = requests.Session()
        
        # V56: Anti-Bot Headers
        self.scraper.headers.update({
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
            'Accept-Language': 'en-US,en;q=0.9'
        })

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
 
    def workers_ai_run(self, model, inputs):
        headers = {"Authorization": f"Bearer {self.config['cf_token']}"}
        input = { "messages": inputs }
        try:
            response = requests.post(
                f"https://api.cloudflare.com/client/v4/accounts/{self.config['cf_account_id']}/ai/run/{model}", 
                headers=headers, json=input, timeout=30)
            return response.json()
        except Exception as e:
            log(f"AI Request failed: {e}", RED, "⚠️")
            return {"result": {"response": "FALSE"}}

    def get_summarize_from_ai(self, description):
        inputs = [
            { "role": "system", "content": self.config['thread_prompt'] },
            { "role": "user", "content": description}
        ]
        output = self.workers_ai_run(self.config['model'], inputs)
        try: return output['result']['response'].split('END')[0]
        except: return "AI 摘要失败。"

    def get_filter_from_ai(self, description):
        inputs = [
            { "role": "system", "content": self.config['filter_prompt'] },
            { "role": "user", "content": description}
        ]
        output = self.workers_ai_run(self.config['model'], inputs)
        try: return output['result']['response'].split('END')[0]
        except: return "FALSE"

    def markdown_to_html(self, text):
        text = text.replace("<", "&lt;").replace(">", "&gt;")
        text = re.sub(r'\*\*(.*?)\*\*', r'<b>\1</b>', text)
        text = re.sub(r'\[(.*?)\]\((.*?)\)', r'<a href="\2" style="color:#007bff;text-decoration:none;">\1</a>', text)
        text = text.replace('\n', '<br>')
        return text

    def handle_thread(self, thread_data, extracted_links):
        existing_thread = self.threads_collection.find_one({'link': thread_data['link']})
        if not existing_thread:
            self.threads_collection.insert_one(thread_data)
            # Summarize & Push if really new (double check for redundancy)
            if (datetime.utcnow() - thread_data['pub_date']).total_seconds() <= 86400:
                log(f"AI 正在摘要...", YELLOW, "🤖")
                raw_summary = self.get_summarize_from_ai(thread_data['description'])
                html_summary = self.markdown_to_html(raw_summary)
                
                utc_time = thread_data['pub_date']
                shanghai_time = utc_time + timedelta(hours=8)
                time_str = shanghai_time.strftime('%Y-%m-%d %H:%M')
                
                links_html = ""
                if extracted_links:
                    links_list = "".join([f"• <a href='{link}' style='color:#007bff;'>{link[:30]}...</a><br>" for link in extracted_links[:5]])
                    links_html = f"<div style='margin-top:10px;font-size:12px;'>🔗 <b>其他检测链接:</b><br>{links_list}</div>"

                msg_content = (
                    f"<h4 style='color:#2E8B57;margin-bottom:5px;margin-top:0;'>{thread_data['title']}</h4>"
                    f"<div style='font-size:12px;color:#666;margin-bottom:10px;'>"
                    f"👤 作者: {thread_data['creator']} <span style='margin:0 5px;color:#ddd;'>|</span> 🕒 {time_str}"
                    f"</div>"
                    
                    f"<div style='border-left:4px solid #4CAF50;padding:8px;background:#f1f8e9;color:#333;margin-bottom:10px;font-size:14px;line-height:1.5;'>"
                    f"<b>🤖 AI 深度分析 & 套餐:</b><br>{html_summary}</div>"
                    f"{links_html}"
                    f"<div style='margin-top:15px;'><a href='{thread_data['link']}' style='display:inline-block;padding:8px 15px;background:#2E8B57;color:white;text-decoration:none;border-radius:4px;font-weight:bold;'>👉 查看原帖 (Source)</a></div>"
                )
                self.notifier.send_html_message(thread_data['title'], msg_content)
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
        for comment in comments:
            try:
                author = comment.find('a', class_='Username').text
                if author != thread_data['creator']: continue # Only OP replies
                
                comment_id = comment['id'].replace('Comment_', '')
                message = comment.find('div', class_='Message').text.strip()
                date_str = comment.find('time')['datetime']
                created_at = datetime.strptime(date_str, "%Y-%m-%dT%H:%M:%S%z").replace(tzinfo=None)
                
                c_data = {
                    'comment_id': comment_id, 'thread_link': thread_data['link'],
                    'author': author, 'message': message, 'created_at': created_at,
                    'url': f"{thread_data['link']}#Comment_{comment_id}"
                }
                self.handle_comment(c_data, thread_data)
            except: pass

    def fetch_comments(self, thread_data):
        thread_info = self.threads_collection.find_one({'link': thread_data['link']})
        try: last_page = int(thread_info.get('last_page', 1))
        except: last_page = 1
        if last_page < 1: last_page = 1

        while True:
            page_url = f"{thread_data['link']})/p{last_page}"
            try:
                # V54: Polite delay to reduce 403 chance
                time.sleep(1) 
                
                resp = self.scraper.get(page_url, timeout=20)
                
                if resp.status_code == 200:
                    soup = BeautifulSoup(resp.text, 'html.parser')
                    max_page = self.get_max_page_from_soup(soup)
                    log(f"   📄 进度: 第 {last_page} 页 / 共 {max_page} 页", GRAY)

                    self.parse_let_comment(resp.text, thread_data)
                    
                    if last_page < max_page:
                        last_page += 1
                    else:
                        self.threads_collection.update_one({'link': thread_data['link']}, {'$set': {'last_page': max_page}})
                        break
                else:
                    # V54: Silent Stop on 403/Error (No logs)
                    break 
            except Exception:
                # V54: Silent Stop on Network Exception
                break

    def handle_comment(self, comment_data, thread_data):
        if not self.comments_collection.find_one({'comment_id': comment_data['comment_id']}):
            self.comments_collection.update_one({'comment_id': comment_data['comment_id']}, {'$set': comment_data}, upsert=True)
            if (datetime.utcnow() - comment_data['created_at']).total_seconds() <= 86400:
                log(f"[新评论] 楼主在 {thread_data['title']} 回复了", YELLOW, "💬")
                ai_resp = self.get_filter_from_ai(comment_data['message'])
                if "FALSE" not in ai_resp:
                    log(f"关键词匹配! 推送中...", GREEN, "🚀")
                    
                    utc_time = comment_data['created_at']
                    shanghai_time = utc_time + timedelta(hours=8)
                    time_str = shanghai_time.strftime('%Y-%m-%d %H:%M')

                    msg_content = (
                        f"<h4 style='color:#007bff;margin-bottom:5px;'>💬 楼主新回复</h4>"
                        f"<div style='font-size:12px;color:#666;margin-bottom:10px;'>"
                        f"📌 来源: {thread_data['title']} <span style='margin:0 5px;color:#ddd;'>|</span> 🕒 {time_str}"
                        f"</div>"
                        f"<div style='background:#f8f9fa;padding:10px;border:1px solid #eee;border-radius:5px;color:#333;'><b>AI 分析:</b><br>{ai_resp}</div>"
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
                pub_date = datetime.strptime(item.find('pubDate').text, "%a, %d %b %Y %H:%M:%S +0000")
                
                t_data = {
                    'cate': 'let', 'title': item.find('title').text, 'link': link,
                    'description': processed_description,
                    'pub_date': pub_date,
                    'created_at': datetime.utcnow(), 'creator': item.find('dc:creator').text, 'last_page': 1
                }

                # --- V57 Core Logic ---
                
                # 1. Check if thread is already known
                is_known_thread = self.threads_collection.find_one({'link': link})
                thread_age = (datetime.utcnow() - pub_date).total_seconds()

                if is_known_thread:
                    # Case A: Known thread (Old or New). 
                    # If it appears in RSS, it's active. Scan for replies.
                    log(f"[{t_data['creator']}] {t_data['title']} (追踪中...)", CYAN, "🔎")
                    self.fetch_comments(t_data)
                    
                else:
                    # Case B: Unknown thread.
                    if thread_age > 86400:
                        # B1: Stranger is older than 24h -> Ignore (Don't backfill old data)
                        continue
                    else:
                        # B2: Stranger is fresh -> Adopt it!
                        log(f"[{t_data['creator']}] {t_data['title']} (发现新帖)", GREEN, "🆕")
                        is_new = self.handle_thread(t_data, extracted_links)
                        if is_new: new_count += 1
                        self.fetch_comments(t_data)

            except Exception as e: pass
        if new_count == 0: log(f"完成。无新内容。", GRAY, "✅")

    def start_monitoring(self):
        log("=== 监控服务启动 (V57 Smart Retention) ===", GREEN, "🚀")
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
cfscrape
urllib3<2.0
lxml
EOF

    echo "--- 正在写入推送脚本 (V42) ---"
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

run_apply_app_update() {
    check_service_exists 
    _write_python_files_and_deps
    run_update_config_prompt
    echo "更新依赖..."
    "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt" > /dev/null
    run_restart
    echo -e "${GREEN}完成!${NC}"
}

run_install() {
    echo "=== 部署 ForumMonitor (V57) ==="
    apt-get update
    apt-get install -y python3 python3-pip python3-venv nodejs jq curl gnupg lsb-release

    local C=$(lsb_release -cs)
    local G="/usr/share/keyrings/mongodb-server.gpg"
    if [ "$C" == "bookworm" ]; then
        curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | gpg --dearmor -o $G
        echo "deb [ arch=amd64,arm64 signed-by=$G ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/7.0 main" | tee /etc/apt/sources.list.d/mongodb-org.list
    else
        curl -fsSL https://www.mongodb.org/static/pgp/server-6.0.asc | gpg --dearmor -o $G
        echo "deb [ arch=amd64,arm64 signed-by=$G ] https://repo.mongodb.org/apt/debian bullseye/mongodb-org/6.0 main" | tee /etc/apt/sources.list.d/mongodb-org.list
    fi
    apt-get update && apt-get install -y mongodb-org
    systemctl start mongod && systemctl enable mongod

    mkdir -p "$APP_DIR/data"
    _write_python_files_and_deps
    
    if [ ! -d "$VENV_DIR" ]; then python3 -m venv "$VENV_DIR"; fi
    "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt"

    if [ ! -f "$CONFIG_FILE" ]; then
        read -p "Pushplus Token: " PT; read -p "CF Token: " CT; read -p "CF Account ID: " CID
        local PROMPT="你是一个中文智能助手。请分析这条 VPS 优惠信息，按以下格式输出分析：\n优点：xxx\n缺点：xxx\n适合用途：xxx\n可用区域：xxx\n支付方式：xxx\n合适套餐：(推荐一款)\n\n然后列出**所有**提到的 VPS 套餐。请**务必**将该套餐的购买链接(如有)放在对应行的末尾。格式：\n📦 套餐列表：\n- <配置> | <价格> | <优惠码> | [购买链接](URL)"
        jq -n --arg pt "$PT" --arg ct "$CT" --arg cid "$CID" --arg prompt "$PROMPT" \
           '{config: {pushplus_token: $pt, cf_token: $ct, cf_account_id: $cid, model: "@cf/meta/llama-3-8b-instruct", thread_prompt: $prompt, filter_prompt: "内容：XXX", frequency: 600}}' > "$CONFIG_FILE"
    else
        run_update_config_prompt
    fi
    cat <<'EOF' > "$APP_DIR/example.json"
{"config": {"pushplus_token": "TOKEN", "frequency": 600}}
EOF

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
    
    echo -e "${GREEN}安装完成! 正在重新加载管理脚本...${NC}"
    sleep 2
    exec "$0"
}

show_menu() {
    clear
    show_dashboard
    echo -e "${GREEN} ForumMonitor Manager (V57)${NC}"
    echo -e "${GRAY}----------------------------------------------------------------${NC}"
    
    echo -e "${CYAN} [基础管理]${NC}"
    printf "  %-4s %-12s %b%s%b\n" "1." "install" "$GRAY" "安装/重置 (环境与依赖)" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "2." "uninstall" "$GRAY" "彻底卸载 (清理数据)" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "3." "update" "$GRAY" "更新脚本 (获取最新功能)" "$NC"
    
    echo -e "${CYAN} [服务控制]${NC}"
    printf "  %-4s %-12s %b%s%b\n" "4." "start" "$GRAY" "启动服务" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "5." "stop" "$GRAY" "停止服务" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "6." "restart" "$GRAY" "重启服务" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "7." "keepalive" "$GRAY" "开启保活 (Crontab)" "$NC"

    echo -e "${CYAN} [配置与监控]${NC}"
    printf "  %-4s %-12s %b%s%b\n" "8." "edit" "$GRAY" "修改密钥 (API配置)" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "9." "frequency" "$GRAY" "调整频率 (秒)" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "10." "status" "$GRAY" "详细状态 (运行详情)" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "11." "logs" "$GRAY" "实时日志 (显示标题+作者)" "$NC"

    echo -e "${CYAN} [功能测试]${NC}"
    printf "  %-4s %-12s %b%s%b\n" "12." "test-ai" "$GRAY" "测试 AI 连通性" "$NC"
    printf "  %-4s %-12s %b%s%b\n" "13." "test-push" "$GRAY" "测试消息推送" "$NC"

    echo -e "${GRAY}----------------------------------------------------------------${NC}"
    echo -e "  q. quit         退出菜单"
}

main() {
    if [ "$EUID" -ne 0 ]; then echo "请使用 root 运行"; exit 1; fi
    if [ "${1:-}" == "--post-update" ]; then run_apply_app_update; read -n 1 -s -r -p "按键进入菜单..."; 
    elif [ -n "${1:-}" ]; then
        case "$1" in
            install|1) run_install ;;
            uninstall|2) run_uninstall ;;
            start|3) run_update ;;
            update|3) run_update ;; # Handle both name and number for update if needed, though case 3 is update now
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
            monitor|14) run_monitor_logic ;;
            *) show_menu; exit 1 ;;
        esac; exit 0
    fi
    while true; do
        show_menu; echo -e -n "${YELLOW}选项: ${NC}"; read CMD
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
        esac
    done
}
main "$@"
