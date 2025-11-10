#!/bin/bash

# --- 此脚本用于在 Debian 11/12 上管理 ForumMonitor 服务 ---
#
# 用法: ./deploy_final.sh [command|number]
#       (安装后, 可使用 'fm' 快捷键)
#
# Commands:
#   1. install    (默认) 安装/重装服务 (Mongo, Python, systemd)。
#   2. uninstall  完全移除服务、依赖和数据。
#   3. start      启动服务。
#   4. stop       停止服务。
#   5. restart    重启服务。
#   6. edit       交互式地修改 API 密钥 (Pushplus, CF)。
#   7. frequency  修改脚本遍历时间 (秒)。
#   8. status     查看服务运行状态。
#   9. logs       查看脚本实时日志 (按 Ctrl+C 退出)。
#  10. test-push  发送一条 Pushplus 测试消息。
#   0. help       显示此帮助信息。
#   q. quit       退出菜单 (仅在交互模式下)。
#
# --- (c) 2025 - 自动生成 (V9 - 包含推送测试) ---

set -e
set -u

# --- 1. 定义全局配置变量 ---
APP_DIR="/opt/forum-monitor"
VENV_DIR="$APP_DIR/venv"
SERVICE_NAME="forum-monitor"
PYTHON_SCRIPT_NAME="core.py"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
MONGO_APT_SOURCE="/etc/apt/sources.list.d/mongodb-org-6.0.list"
MONGO_GPG_KEY="/usr/share/keyrings/mongodb-server-6.0.gpg"
CONFIG_FILE="$APP_DIR/data/config.json"
SHORTCUT_PATH="/usr/local/bin/fm"

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# --- 2. 辅助功能 ---

check_service_exists() {
    if [ ! -f "$SYSTEMD_SERVICE_FILE" ]; then
        echo "错误: 服务 $SERVICE_NAME 未安装。"
        echo "请先运行 'fm 1' (安装)。"
        exit 1
    fi
}

check_jq() {
    if ! command -v jq &> /dev/null; then
        echo "--- 需要 'jq' (JSON 处理器) 来安全地编辑配置。---"
        echo "--- 正在安装 jq... ---"
        apt-get update
        apt-get install -y jq
    fi
}

# --- 3. 管理功能 ---

run_start() {
    check_service_exists
    echo "--- 正在启动 $SERVICE_NAME 服务... ---"
    systemctl start $SERVICE_NAME
    echo "服务已启动。使用 'systemctl status $SERVICE_NAME' 查看状态。"
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
    echo "服务已重启。将显示状态："
    systemctl status $SERVICE_NAME --no-pager
}

run_edit_config() {
    check_service_exists
    check_jq

    echo "--- 交互式修改 API 密钥 ---"
    echo "--- (按 Enter 键保留当前值) ---"

    local CURRENT_PUSHPLUS_TOKEN=$(jq -r '.config.pushplus_token' "$CONFIG_FILE")
    local CURRENT_CF_TOKEN=$(jq -r '.config.cf_token' "$CONFIG_FILE")
    local CURRENT_CF_ACCOUNT_ID=$(jq -r '.config.cf_account_id' "$CONFIG_FILE")

    read -p "Pushplus Token (当前: ***${CURRENT_PUSHPLUS_TOKEN: -6}): " NEW_PUSHPLUS_TOKEN
    read -p "Cloudflare API Token (当前: ***${CURRENT_CF_TOKEN: -6}): " NEW_CF_TOKEN
    read -p "Cloudflare Account ID (当前: $CURRENT_CF_ACCOUNT_ID): " NEW_CF_ACCOUNT_ID

    [ -z "$NEW_PUSHPLUS_TOKEN" ] && NEW_PUSHPLUS_TOKEN="$CURRENT_PUSHPLUS_TOKEN"
    [ -z "$NEW_CF_TOKEN" ] && NEW_CF_TOKEN="$CURRENT_CF_TOKEN"
    [ -z "$NEW_CF_ACCOUNT_ID" ] && NEW_CF_ACCOUNT_ID="$CURRENT_CF_ACCOUNT_ID"

    jq \
        --arg p_token "$NEW_PUSHPLUS_TOKEN" \
        --arg cf_token "$NEW_CF_TOKEN" \
        --arg cf_id "$NEW_CF_ACCOUNT_ID" \
        '.config.pushplus_token = $p_token | .config.cf_token = $cf_token | .config.cf_account_id = $cf_id' \
        "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

    echo "--- 配置已更新。 ---"
    run_restart
}

run_edit_frequency() {
    check_service_exists
    check_jq

    local CURRENT_FREQ=$(jq -r '.config.frequency' "$CONFIG_FILE")
    echo "--- 修改脚本遍历时间 ---"
    echo "当前遍历间隔: $CURRENT_FREQ 秒 (即 $(($CURRENT_FREQ / 60)) 分钟)"
    read -p "请输入新的间隔时间 (单位: 秒): " NEW_FREQ

    if ! [[ "$NEW_FREQ" =~ ^[0-9]+$ ]]; then
        echo "错误: 输入无效，必须是一个数字。"
        return 1
    fi

    jq '.config.frequency = $NEW_FREQ_INT' --argjson NEW_FREQ_INT "$NEW_FREQ" \
        "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

    echo "遍历时间已更新为 $NEW_FREQ 秒。"
    run_restart
}

run_status() {
    check_service_exists
    echo "--- 正在显示 $SERVICE_NAME 服务状态... ---"
    systemctl status $SERVICE_NAME --no-pager
}

run_logs() {
    check_service_exists
    echo "--- 正在显示 $SERVICE_NAME 实时日志... ---"
    echo "--- (按 Ctrl+C 退出日志并返回菜单) ---"
    sleep 2
    # -f = follow (实时)
    journalctl -u $SERVICE_NAME -f
}

# (新) Pushplus 推送测试
run_test_push() {
    check_service_exists
    check_jq

    echo "--- 正在测试 Pushplus 推送... ---"
    
    # 检查 Token 是否已在 config.json 中设置
    local PUSHPLUS_TOKEN=$(jq -r '.config.pushplus_token' "$CONFIG_FILE")
    if [ -z "$PUSHPLUS_TOKEN" ] || [ "$PUSHPLUS_TOKEN" == "YOUR_PUSHPLUS_TOKEN_HERE" ]; then
        echo "错误: Pushplus Token 未在配置中设置。"
        echo "请先运行 'fm 6' (edit) 来设置 Token。"
        return 1
    fi

    # 定义要执行的 Python 内联命令
    # 1. 将 APP_DIR 添加到 sys.path, 这样 Python 才能找到 'send' 模块
    # 2. 导入 NotificationSender
    # 3. 像 core.py 一样，使用 config_path 初始化它
    # 4. 发送测试消息
    local PY_COMMAND="import sys; sys.path.append('$APP_DIR'); from send import NotificationSender; print('Initializing NotificationSender...'); sender = NotificationSender('$CONFIG_FILE'); print('Sending test message...'); sender.send_message('ForumMonitor: Test Message\n\nThis is a test of the Pushplus integration from your management script.'); print('Test message sent. Please check your device.')"
    
    # 在 Python 虚拟环境中执行该命令
    "$VENV_DIR/bin/python" -c "$PY_COMMAND"
}


# --- 4. 核心安装/卸载功能 ---

run_uninstall() {
    echo "=== 正在开始卸载 ForumMonitor ==="
    
    echo "--- 正在停止并禁用 $SERVICE_NAME 服务... ---"
    if systemctl is-active --quiet $SERVICE_NAME; then systemctl stop $SERVICE_NAME; fi
    if systemctl is-enabled --quiet $SERVICE_NAME; then systemctl disable $SERVICE_NAME; fi
    
    echo "--- 正在停止并禁用 mongod 服务... ---"
    if systemctl is-active --quiet mongod; then systemctl stop mongod; fi
    if systemctl is-enabled --quiet mongod; then systemctl disable mongod; fi
    
    echo "--- 正在移除 systemd 文件... ---"
    rm -f "$SYSTEMD_SERVICE_FILE"
    systemctl daemon-reload
    systemctl reset-failed
    
    echo "--- 正在移除应用程序目录 $APP_DIR... ---"
    rm -rf "$APP_DIR"
    
    echo "--- 正在卸载 (purge) mongodb-org... ---"
    apt-get purge -y mongodb-org
    
    echo "--- 正在移除 MongoDB apt 源文件... ---"
    rm -f "$MONGO_APT_SOURCE"
    rm -f "$MONGO_GPG_KEY"
    
    echo "--- 正在移除快捷方式 $SHORTCUT_PATH... ---"
    rm -f "$SHORTCUT_PATH"
    
    echo "--- 正在运行 apt autoremove... ---"
    apt-get autoremove -y
    apt-get update
    
    echo "=== 卸载完成。 ==="
}

run_install() {
    echo "=== 正在开始部署 ForumMonitor 服务 (完整版) ==="
    echo "将安装到: $APP_DIR"

    # A. 安装系统依赖 (Python)
    echo "--- 正在更新软件包列表并安装 Python 依赖... ---"
    apt-get update
    apt-get install -y python3 python3-pip python3-venv

    # B. 安装系统依赖 (MongoDB)
    echo "--- 正在安装 MongoDB (脚本的数据库依赖)... ---"
    apt-get install -y curl gnupg
    curl -fsSL https://www.mongodb.org/static/pgp/server-6.0.asc | gpg --dearmor -o $MONGO_GPG_KEY
    echo "deb [ arch=amd64,arm64 signed-by=$MONGO_GPG_KEY ] https://repo.mongodb.org/apt/debian bullseye/mongodb-org/6.0 main" | tee $MONGO_APT_SOURCE
    apt-get update
    apt-get install -y mongodb-org
    echo "--- 正在启动并启用 MongoDB (mongod)... ---"
    systemctl start mongod
    systemctl enable mongod

    # C. 创建目录结构
    echo "--- 正在创建应用程序目录: $APP_DIR/data ---"
    mkdir -p "$APP_DIR/data"

    # D. 创建 Python 脚本 (core.py)
    echo "--- 正在创建 Python 主程序: $APP_DIR/$PYTHON_SCRIPT_NAME ---"
    cat <<'EOF' > "$APP_DIR/$PYTHON_SCRIPT_NAME"
import json
import time
import requests
from bs4 import BeautifulSoup
from datetime import datetime
from send import NotificationSender
import os
from pymongo import MongoClient
import cfscrape
import shutil

scraper = cfscrape.create_scraper()  # returns a CloudflareScraper instance




class ForumMonitor:
    def __init__(self, config_path='data/config.json'):
        self.config_path = config_path
        self.proxy_host = os.getenv("PROXY_HOST", None)  # 从环境变量读取代理配置
        self.mongo_host = os.getenv("MONGO_HOST", 'mongodb://localhost:27017/')  # 从环境变量读取代理配置
        self.load_config()

        # 连接到 MongoDB
        self.mongo_client = MongoClient(self.mongo_host) 
        self.db = self.mongo_client['forum_monitor']  # 使用数据库 'forum_monitor'
        self.threads_collection = self.db['threads']  # 线程集合
        self.comments_collection = self.db['comments']  # 评论集合
        try:
            # 创建索引。如果索引已经存在，MongoDB 会自动跳过创建，无需担心重复。
            self.threads_collection.create_index('link', unique=True)
            self.comments_collection.create_index('comment_id', unique=True)
        except Exception as e:
            print(e)


    # 加载配置文件
    def load_config(self):
        try:
            # 检查配置文件是否存在
            if not os.path.exists(self.config_path):
                print(f"{self.config_path} 不存在，复制到 {self.config_path}")
                shutil.copy('example.json', self.config_path)
      
            with open(self.config_path, 'r') as f:
                self.config = json.load(f)['config']
                self.notifier = NotificationSender(self.config_path)  # 创建通知发送器
            print("配置文件加载成功")
        except Exception as e:
            print(f"加载配置失败: {e}")
            self.config = {}

 
    def workers_ai_run(self, model, inputs):
        headers = {"Authorization": f"Bearer {self.config['cf_token']}"}
        input = { "messages": inputs }
        response = requests.post(f"https://api.cloudflare.com/client/v4/accounts/{self.config['cf_account_id']}/ai/run/{model}", headers=headers, json=input)
        return response.json()

    # 用AI总结Thread
    def get_summarize_from_ai(self, description):
        inputs = [
            { "role": "system", "content": self.config['thread_prompt'] }, # "你是一个中文智能助手，帮助我筛选一个 VPS (Virtual Private Server, 虚拟服务器) 交流论坛的信息。接下来我要给你一条信息，请你用50字简短总结，并用100字介绍其提供的价格最低的套餐（介绍其价格、配置以及对应的优惠码，如果有）。格式为：摘要：xxx\n优惠套餐：xxx"
            { "role": "user", "content": description}
        ]

        output = self.workers_ai_run(self.config['model'], inputs) # "@cf/qwen/qwen1.5-14b-chat-awq"
        # print(output)
        return output['result']['response'].split('END')[0]

    # 用AI判断评论是否值得推送
    def get_filter_from_ai(self, description):
        inputs = [
            { "role": "system", "content": self.config['filter_prompt'] }, # "你是一个中文智能助手，帮助我筛选一个 VPS (Virtual Private Server, 虚拟服务器) 交流论坛的信息。接下来我要给你一条信息，如果满足筛选规则，请你返回文段翻译，如果文段超过100字，翻译后再进行摘要，如果不满足，则返回 "FALSE"。 筛选条件：这条评论需要提供了一个新的优惠活动 discount，或是发起了一组抽奖 giveaway，或是提供了优惠码 code，或是补充了供货 restock，除此之外均返回FALSE。返回格式：内容：XXX 或者 FALSE。"
            { "role": "user", "content": description}
        ]

        output = self.workers_ai_run(self.config['model'], inputs) # "@cf/qwen/qwen1.5-14b-chat-awq"
        print(output)
        return output['result']['response'].split('END')[0]



    def handle_thread(self, thread_data):
        # 检查是否已经有该线程
        existing_thread = self.threads_collection.find_one({'link': thread_data['link']})

        if not existing_thread:
            # 存储 RSS 线程到 MongoDB

            self.threads_collection.insert_one(thread_data)  # 仅当线程不存在时插入

            print(f"    [检测到新线程] 已存储: {thread_data['title']}")

            # 解析 pub_date 为 datetime 对象
            time_diff = datetime.utcnow() - thread_data['pub_date']

            # 如果文章发布时间在当前时间的一天内，则发送通知
            if time_diff.total_seconds() <= 24 * 60 * 60:  # 24小时以内
                # 格式化发布时间为所需格式
                formatted_pub_date = thread_data['pub_date'].strftime("%Y/%m/%d %H:%M")
                
                # 生成文章概要
                summary = self.get_summarize_from_ai(thread_data['description'])
  
                # 创建消息内容
                message = (
                    f"{thread_data['cate'].upper()} 新促销\n"
                    f"标题：{thread_data['title']}\n"
                    f"作者：{thread_data['creator']}\n"  # 如果有作者信息，可替换 '未知' 为实际值
                    f"发布时间：{formatted_pub_date}\n\n"
                    f"{thread_data['description'][:200]}...\n\n"
                    f"{summary}\n\n"
                    f"{thread_data['link']}"
                )

                print(f"    [推送] 正在推送新线程: {thread_data['title']}")
                self.notifier.send_message(message)
        else:
            print(f"    [遍历] 线程已存在，跳过新建: {thread_data['title']}")

    # 获取线程所有页面的评论
    def fetch_comments(self, thread_data):
        thread_info = self.threads_collection.find_one({'link': thread_data['link']})
        if thread_info:
            last_page = thread_info.get('last_page', 1)
        while True:
            # 不同类型可能要考虑不同构建
            if thread_data['cate'] == 'let':
                page_url = f"{thread_data['link']})/p{last_page}"  # 拼接分页 URL

            response = scraper.get(page_url)
            if response.status_code == 200:
                print(f"    [遍历] 正在抓取评论页: {page_url}")
                page_content = response.text
                if thread_data['cate'] == 'let':
                    self.parse_let_comment(page_content, thread_data)
                    

                last_page += 1
                time.sleep(2)  # 可以适当延时防止过于频繁的请求
            else:
                print(f"    [遍历] 已获取所有评论页 (共 {last_page-1} 页)。")
                # 更新 MongoDB 中该线程的 last_page
                self.threads_collection.update_one(
                    {'link': thread_data['link']},
                    {'$set': {'last_page': last_page-1}}
                )
                break  # 如果没有更多页面，则停止抓取

    def handle_comment(self, comment_data, thread_data):
        existing_comment = self.comments_collection.find_one({'comment_id': comment_data['comment_id']})
    
        if not existing_comment:
            # 存储评论到 MongoDB，使用 comment_id 确保唯一性
            self.comments_collection.update_one(
                {'comment_id': comment_data['comment_id']},  # 使用 comment_id 作为唯一标识符
                {'$set': comment_data},
                upsert=True  # 如果该评论不存在则插入，否则更新
            )

            time_diff = datetime.utcnow() - comment_data['created_at']
            # 如果文章发布时间在当前时间的一天内，则发送通知
            if time_diff.total_seconds() <= 24 * 60 * 60 and comment_data['author'] == thread_data['creator']:  # 24小时以内
                print(f"      [检测到新评论] (作者: {comment_data['author']}) 正在提交给 AI 过滤器...")
                
                ai_response = self.get_filter_from_ai(comment_data['message'])
                print(f"      [AI 响应] {ai_response}")
                
                if not "FALSE" in ai_response:
                    # 格式化发布时间为所需格式
                    formatted_pub_date = comment_data['created_at'].strftime("%Y/%m/%d %H:%M")
    
                    # 创建消息内容
                    message = (
                        f"{thread_data['cate'].upper()} 新评论\n"
                        f"作者：{comment_data['author']}\n"  # 如果有作者信息，可替换 '未知' 为实际值
                        f"发布时间：{formatted_pub_date}\n\n"
                        f"{comment_data['message'][:200]}...\n"
                        f"{ai_response[:200]}...\n\n"
                        f"{comment_data['url']}"
                    )
    
                    print(f"      [推送] AI 过滤器通过，正在推送新评论: {comment_data['url']}")
                    self.notifier.send_message(message)
                else:
                    print(f"      [AI 过滤器] 跳过评论 (ID: {comment_data['comment_id']})")

    # 检查 RSS
    def check_let(self, url = "https://lowendtalk.com/categories/offers/feed.rss"):
        print(f"正在检查 LET: {url}")
        response = scraper.get(url)
        if response.status_code == 200:
            rss_feed = response.text
            self.parse_let(rss_feed)
        else:
            print(f"无法获取 LET 数据: {response.status_code}")
 

    # 解析 RSS 内容
    def parse_let(self, rss_feed):
        soup = BeautifulSoup(rss_feed, 'xml')
        items = soup.find_all('item')
        # 只看前 3 个
        for item in items[:3]:
            # print(item)
            title = item.find('title').text
            link = item.find('link').text
            description = BeautifulSoup(item.find('description').text,'lxml').text
            pub_date = item.find('pubDate').text
            creator = item.find('dc:creator').text
            
            print(f"  [遍历] 正在检查 LET 帖子: {title} (作者: {creator})")

            thread_data = {
                'cate': 'let',
                'title': title,
                'link': link,
                'description': description,
                'pub_date': datetime.strptime(pub_date, "%a, %d %b %Y %H:%M:%S +0000"),
                'created_at': datetime.utcnow(),
                'creator': creator,
                'last_page': 1  # 默认从第一页开始抓取
            }

            self.handle_thread(thread_data)

            # 开始抓取
            self.fetch_comments(thread_data)
            
    # 解析页面信息
    def parse_let_comment(self, page_content, thread_data):
        soup = BeautifulSoup(page_content, 'html.parser')
        # 获取所有评论
        comments = soup.find_all('li', class_='ItemComment')
        for comment in comments:
            # 通过 ID 获取评论唯一标识
            comment_id = comment.get('id')
            if not comment_id:
                print('nocommentid')
                continue  # 如果没有 id，则跳过此评论
            
            comment_id = comment_id.split('_')[1]  # 提取 id 中的数字部分

            # 提取评论中的数据
            author = comment.find('a', class_='Username').text
            message = comment.find('div', class_='Message').text.strip()
            created_at = comment.find('time')['datetime']
            
            if not author == thread_data['creator'] or comment.find('div',class_="QuoteText"):
                continue

            comment_data = {
                    'comment_id': f'{thread_data["cate"]}_{comment_id}',  # 使用 comment_id 作为唯一标识符
                    'thread_url': thread_data['link'],
                    'author': author,
                    # 'message': message,
                    # 优化存储
                    'message': message[:200],
                    'created_at': datetime.strptime(created_at, "%Y-%m-%dT%H:%M:%S+00:00"),
                    'created_at_recorded': datetime.utcnow(),
                    'url': f"https://lowendtalk.com/discussion/comment/{comment_id}/#Comment_{comment_id}"
                }
            
            self.handle_comment(comment_data, thread_data)

    # 监控主循环
    def start_monitoring(self):
        print(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} 开始监控...")
        frequency = self.config.get('frequency', 600)  # 默认每10分钟检测一次
        
        debug = True

        while True:
            if debug:
                    print(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} 开始遍历...")
                    self.check_let()  # 检查 RSS
                    print(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} 遍历完成...")
            else:
                try:
                    print(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} 开始遍历...")
                    self.check_let()  # 检查 RSS
                    print(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} 遍历完成...")
                except Exception as e:
                    print(f"检测过程出现错误: {e}")
            time.sleep(frequency)

    # 外部重载配置方法
    def reload(self):
        print("重新加载配置...")
        self.load_config()

# 示例运行
if __name__ == "__main__":
    monitor = ForumMonitor(config_path='data/config.json')
    monitor.start_monitoring()
EOF

    # E. 创建 Python 依赖文件 (requirements.txt)
    echo "--- 正在创建 Python 依赖文件: $APP_DIR/requirements.txt ---"
    cat <<EOF > "$APP_DIR/requirements.txt"
requests
beautifulsoup4
pymongo
cfscrape
urllib3<2.0
lxml
EOF

    # F. 创建 send.py (Pushplus 版本) - (*** V9: 已改进 ***)
    echo "--- 正在创建 Pushplus 通知脚本: $APP_DIR/send.py ---"
    cat <<'EOF' > "$APP_DIR/send.py"
import json
import requests
import os
# (新) 添加重试相关的导入
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

class NotificationSender:
    def __init__(self, config_path='data/config.json'):
        print("通知发送器: 正在初始化 Pushplus (带重试功能)...")
        self.config_path = config_path
        self.token = ""
        
        # (新) 在此处创建带重试策略的 session
        self.session = requests.Session()
        retry_strategy = Retry(
            total=3,  # 总共重试3次
            status_forcelist=[429, 500, 502, 503, 504], # 对这些服务器错误状态码也进行重试
            allowed_methods=["POST"],
            backoff_factor=1  # 每次重试的等待时间会增加 (例如: 1s, 2s, 4s)
        )
        adapter = HTTPAdapter(max_retries=retry_strategy)
        self.session.mount("https://", adapter)
        self.session.mount("http://", adapter)
        
        self.load_config()

    def load_config(self):
        try:
            # 确保配置文件存在
            if not os.path.exists(self.config_path):
                print(f"警告: {self.config_path} 不存在, 将在 core.py 首次运行时创建。")
                return

            with open(self.config_path, 'r') as f:
                config = json.load(f)['config']
            
            self.token = config.get('pushplus_token', '')
            
            if not self.token:
                print("警告: 'pushplus_token' 未在 config.json 中配置，通知将无法发送。")
        except Exception as e:
            print(f"加载 Pushplus 配置失败: {e}")

    def send_message(self, message):
        if not self.token or self.token == "YOUR_PUSHPLUS_TOKEN_HERE":
            print("错误: Pushplus token 未配置，无法发送。跳过通知。")
            print("====== [ 虚拟通知 (请检查 config.json) ] ======")
            print(message)
            print("==============================================")
            return

        # Pushplus 消息通常需要标题和内容
        # 我们将消息的第一行作为标题，其余作为内容
        try:
            lines = message.split('\n', 1)
            title = lines[0]
            content = lines[1] if len(lines) > 1 else title
        except Exception:
            title = "论坛新通知"
            content = message

        # (新) 【修复1】改用 HTTPS 协议
        pushplus_url = "https://www.pushplus.plus/send"
        payload = {
            "token": self.token,
            "title": title,
            "content": content,
            "template": "markdown" # (新) 【修复4】改用 markdown
        }
        
        try:
            # (新) 【修复2】使用 session 发送请求，并保持15秒的单次连接超时
            response = self.session.post(pushplus_url, json=payload, timeout=15)
            response.raise_for_status() # 如果发生4xx或5xx错误，则抛出异常

            # Pushplus 成功响应 (code 200) 也会在 raise_for_status() 通过
            response_data = response.json()
            if response_data.get('code') == 200:
                print(f"成功发送通知: {title}")
            else:
                print(f"Pushplus 通知发送失败 (API 错误): {response_data.get('msg', '未知错误')}")
                
        except requests.exceptions.RequestException as e:
            # (新) 【修复5】 增强的错误日志
            print(f"错误：PushPlus 通知发送失败 (已重试3次): {e}")
            print("排查建议: 1. 检查服务器能否访问外网。 2. 检查服务器防火墙或云服务商安全组是否允许出站HTTPS(443)流量。 3. 在服务器上执行 'curl -v https://www.pushplus.plus/send' 进行测试。")
        except Exception as e:
            print(f"发送 Pushplus 通知时出现未知错误: {e}")

EOF

    # G. 交互式输入 API 密钥
    echo ""
    echo "--- 正在配置 API 密钥 (将保存到 data/config.json) ---"
    read -p "请输入 Pushplus Token: " PUSHPLUS_TOKEN
    read -p "请输入 Cloudflare API Token: " CF_TOKEN
    read -p "请输入 Cloudflare Account ID (32位字符串, 不是邮箱!): " CF_ACCOUNT_ID
    if [ -z "$PUSHPLUS_TOKEN" ] || [ -z "$CF_TOKEN" ] || [ -z "$CF_ACCOUNT_ID" ]; then
      echo "错误：所有字段都必须填写。部署中止。"
      exit 1
    fi
    echo "--- 密钥输入完毕 ---"
    echo ""

    # H. 创建 data/config.json
    echo "--- 正在创建 *实际* 配置文件: $CONFIG_FILE ---"
    cat << EOF > "$CONFIG_FILE"
{
  "config": {
    "pushplus_token": "$PUSHPLUS_TOKEN",
    "cf_token": "$CF_TOKEN",
    "cf_account_id": "$CF_ACCOUNT_ID",
    "model": "@cf/qwen/qwen1.5-14b-chat-awq",
    "thread_prompt": "你是一个中文智能助手，帮助我筛选一个 VPS (Virtual Private Server, 虚拟服务器) 交流论坛的信息。接下来我要给你一条信息，请你用50字简短总结，并用100字介绍其提供的价格最低的套餐（介绍其价格、配置以及对应的优惠码，如果有）。格式为：摘要：xxx\n优惠套餐：xxx",
    "filter_prompt": "你是一个中文智能助手，帮助我筛选一个 VPS (Virtual Private Server, 虚拟服务器) 交流论坛的信息。接下来我要给你一条信息，如果满足筛选规则，请你返回文段翻译，如果文段超过100字，翻译后再进行摘要，如果不满足，则返回 \"FALSE\"。 筛选条件：这条评论需要提供了一个新的优惠活动 discount，或是发起了一组抽奖 giveaway，或是提供了优惠码 code，或是补充了供货 restock，除此之外均返回FALSE。返回格式：内容：XXX 或者 FALSE。",
    "frequency": 600
  }
}
EOF

    # I. 创建 example.json (作为备份)
    echo "--- 正在创建配置文件模板 (用于参考): $APP_DIR/example.json ---"
    cat <<'EOF' > "$APP_DIR/example.json"
{
  "config": {
    "pushplus_token": "YOUR_PUSHPLUS_TOKEN_HERE",
    "cf_token": "YOUR_CLOUDFLARE_API_TOKEN_HERE",
    "cf_account_id": "YOUR_CLOUDFLARE_ACCOUNT_ID_HERE",
    "model": "@cf/qwen/qwen1.5-14b-chat-awq",
    "thread_prompt": "...",
    "filter_prompt": "...",
    "frequency": 600
  }
}
EOF

    # J. 创建虚拟环境并安装依赖
    echo "--- 正在创建 Python 虚拟环境: $VENV_DIR ---"
    python3 -m venv "$VENV_DIR"
    echo "--- 正在安装 Python 依赖库 (已修复依赖)... ---"
    "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt"

    # K. 创建 systemd 服务文件
    echo "--- 正在创建 systemd 服务: $SYSTEMD_SERVICE_FILE ---"
    cat <<EOF > "$SYSTEMD_SERVICE_FILE"
[Unit]
Description=Forum Monitor Service (Monitors LET with Pushplus)
After=network.target mongod.service
Requires=mongod.service

[Service]
Environment="PROXY_HOST="
Environment="MONGO_HOST=mongodb://localhost:27017/"
User=root
Group=root
WorkingDirectory=$APP_DIR
ExecStart=$VENV_DIR/bin/python $APP_DIR/$PYTHON_SCRIPT_NAME
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    # L. 重新加载、启用并启动服务
    echo "--- 正在重载 systemd, 启用并启动 $SERVICE_NAME 服务 ---"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME.service"
    systemctl start "$SERVICE_NAME.service"
    
    # M. 创建快捷方式
    echo "--- 正在创建快捷方式 '$SHORTCUT_PATH'... ---"
    local SCRIPT_PATH
    SCRIPT_PATH=$(realpath "$0")
    ln -s -f "$SCRIPT_PATH" "$SHORTCUT_PATH"
    echo "快捷方式创建成功。"

    # N. 完成
    echo ""
    echo "================================================="
    echo "=== 部署完成! (已包含所有修复) ==="
    echo ""
    echo "您的应用已安装在: $APP_DIR"
    echo "MongoDB 和 Python 服务都已启动并设置为开机自启。"
    echo -e "您现在可以从任何地方运行 '${YELLOW}fm${NC}' 来打开此管理菜单。"
    echo ""
    echo "--- 如何管理您的服务 ---"
    echo "检查状态: systemctl status $SERVICE_NAME"
    echo "查看日志: journalctl -u $SERVICE_NAME -f"
    echo "检查 Mongo: systemctl status mongod"
    echo "================================================="
}

# --- 5. 绿色帮助菜单 ---
show_help() {
    echo -e "${GREEN}ForumMonitor 管理脚本${NC}"
    echo -e "${GREEN}---------------------------------------------------------${NC}"
    echo -e "${GREEN}用法: $0 [command|number] (运行带参数的命令将直接执行并退出)${NC}"
    echo -e "${GREEN}       $0               (不带参数将启动此交互式菜单)${NC}"
    echo -e "${GREEN}       fm               (安装后可使用此快捷键启动菜单)${NC}"
    echo -e "${GREEN}---------------------------------------------------------${NC}"
    echo -e "${GREEN}  1. install    安装/重装服务 (Mongo, Python, systemd)。${NC}"
    echo -e "${GREEN}  2. uninstall  完全移除服务、依赖和数据。${NC}"
    echo -e "${GREEN}  3. start      启动服务。${NC}"
    echo -e "${GREEN}  4. stop       停止服务。${NC}"
    echo -e "${GREEN}  5. restart    重启服务。${NC}"
    echo -e "${GREEN}  6. edit       交互式地修改 API 密钥 (Pushplus, CF)。${NC}"
    echo -e "${GREEN}  7. frequency  修改脚本遍历时间 (秒)。${NC}"
    echo -e "${GREEN}  8. status     查看服务运行状态。${NC}"
    echo -e "${GREEN}  9. logs       查看脚本实时日志 (按 Ctrl+C 退出)。${NC}"
    echo -e "${GREEN} 10. test-push  发送一条 Pushplus 测试消息。${NC}"
    echo -e "${GREEN}  0. help       显示此帮助信息。${NC}"
    echo -e "${GREEN}  q. quit       退出此菜单。${NC}"
    echo -e "${GREEN}---------------------------------------------------------${NC}"
}

# --- 6. 主脚本逻辑 (带交互式菜单) ---

main() {
    # 检查是否以 root 身份运行
    if [ "$EUID" -ne 0 ]; then
      echo "错误: 此脚本必须以 root 权限运行。"
      exit 1
    fi

    # 如果有参数 (e.g., ./script.sh 1), 则执行该命令并退出
    if [ -n "${1:-}" ]; then
        local COMMAND="$1"
        case "$COMMAND" in
            install|1) run_install ;;
            uninstall|2)
                read -p "您确定要完全卸载 Forum Monitor 及其所有组件（包括 MongoDB）吗？(y/N): " CONFIRM
                if [ "$CONFIRM" == "y" ] || [ "$CONFIRM" == "Y" ]; then run_uninstall; else echo "卸载已取消。"; fi
                ;;
            start|3) run_start ;;
            stop|4) run_stop ;;
            restart|5) run_restart ;;
            edit|6) run_edit_config ;;
            frequency|7) run_edit_frequency ;;
            status|8) run_status ;;
            logs|9) run_logs ;;
            test-push|test|10) run_test_push ;;
            help|0) show_help ;;
            *)
                echo "错误: 未知命令 '$COMMAND'"
                show_help
                exit 1
                ;;
        esac
        exit 0 # 执行完单个命令后退出
    fi

    # 如果没有参数 (e.g., ./script.sh 或 fm), 则启动交互式菜单
    while true; do
        clear
        show_help # 这将显示绿色菜单
        
        echo -e -n "${YELLOW}请输入选项 (或 'q' 退出): ${NC}"
        read MENU_COMMAND

        case "$MENU_COMMAND" in
            install|1)
                run_install
                echo ""
                read -n 1 -s -r -p "安装完成。按任意键返回主菜单..."
                ;;
            uninstall|2)
                read -p "您确定要完全卸载 Forum Monitor 及其所有组件（包括 MongoDB）吗？(y/N): " CONFIRM
                if [ "$CONFIRM" == "y" ] || [ "$CONFIRM" == "Y" ]; then
                    run_uninstall
                    echo "卸载完成。正在退出脚本。"
                    sleep 2
                    break # 退出 while 循环
                else
                    echo "卸载已取消。"
                    read -n 1 -s -r -p "按任意键返回主菜单..."
                fi
                ;;
            start|3)
                run_start
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            stop|4)
                run_stop
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            restart|5)
                run_restart
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            edit|6)
                run_edit_config # 此函数已包含重启
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            frequency|7)
                run_edit_frequency # 此函数已包含重启
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            status|8)
                run_status
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            logs|9)
                run_logs
                # 按 Ctrl+C 退出日志后，将显示此消息
                echo ""
                read -n 1 -s -r -p "已退出日志。按任意键返回主菜单..."
                ;;
            test-push|test|10)
                run_test_push
                read -n 1 -s -r -p "测试完成。按任意键返回主菜单..."
                ;;
            help|0)
                # 循环将自动重新显示帮助
                ;;
            q|Q|quit|exit)
                echo "正在退出..."
                break # 退出 while 循环
                ;;
            *)
                echo "错误: 未知命令 '$MENU_COMMAND'"
                sleep 1
                ;;
        esac
    done
}

# --- 7. 脚本入口 ---
main "$@"
