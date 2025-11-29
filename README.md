


# 📢 ForumMonitor - Intelligent LowEndTalk Deal Hunter

**ForumMonitor** 是一个专为 LowEndTalk (LET) 论坛设计的自动化监控工具。它结合了 **RSS 轮询**与**页面爬取**技术，利用先进的 **AI 模型 (Google Gemini / Cloudflare Workers AI)** 对帖子内容进行智能摘要，并对回复进行语义过滤，只推送真正有价值的优惠信息。

> **核心优势**：拒绝关键词机械匹配，使用 LLM 理解上下文，精准捕捉补货、闪购和赠品信息，过滤灌水回复。

-----

## ✨ 功能特性

  * **🧠 双 AI 引擎支持**：
      * **Google Gemini**：支持 Gemini 2.0 Flash Lite 等模型（推荐，速度快）。
      * **Cloudflare Workers AI**：支持 Llama-3.1-8b 等开源模型。
  * **🚀 智能摘要与过滤**：
      * **新帖摘要**：自动提取 VPS 配置、价格、机房位置、优惠码，生成卡片式报告。
      * **回复筛选**：AI 自动识别回复内容，过滤 "Nice offer"、"Thanks" 等无意义灌水，仅推送补货、降价、抽奖等高价值回复。
  * **📱 多通道推送**：
      * **Telegram**：支持 HTML 格式渲染，排版美观，支持一键直达评论楼层。
      * **Pushplus**：微信推送支持。
      * **独立开关**：可随时在菜单中独立开启或关闭任意推送通道。
  * **🛡️ 极高稳定性 (v50+)**：
      * **单例锁机制**：防止脚本重复运行导致的消息重复。
      * **自愈功能**：启动时自动清理僵尸进程，防止日志乱飘和资源占用。
      * **Watchdog**：内置心跳检测，服务假死自动重启。
  * **⚙️ 强大的管理菜单**：
      * 全交互式 Bash 菜单，支持一键安装、配置修改、日志查看、手动重推等。
      * 支持 **VIP 专线监控**（强制高频扫描特定帖子）。
      * 支持 **指定用户监控**（例如监控特定商家的发言）。

-----

## 🛠️ 安装指南

### 环境要求

  * **OS**: Debian 10+ / Ubuntu 20.04+ (推荐 Debian 12)
  * **Root** 权限
  * **依赖**: Python 3, MongoDB (脚本会自动安装)

### 快速部署

下载脚本并添加执行权限（假设脚本名为 `ForumMonitor.sh`）：

```bash
# 1. 下载脚本 (请替换为你的实际下载方式)
wget -O ForumMonitor.sh https://raw.githubusercontent.com/ypkin/RSS-ForumMonitor-LET/refs/heads/ForumMonitor-with-gemini/ForumMonitor.sh


# 2. 赋予执行权限
chmod +x ForumMonitor.sh

# 3. 运行安装向导
./ForumMonitor.sh
```

首次运行选择 `1. install`，脚本将自动：

1.  更新系统并安装 Python3, venv, pip, jq, curl 等依赖。
2.  安装并启动 MongoDB。
3.  创建 Python 虚拟环境并安装所需库。
4.  引导你输入 API Token (Pushplus, Telegram, Gemini/Cloudflare)。
5.  配置 Systemd 服务并设置开机自启。

-----

## ⚙️ 配置说明

配置文件位于 `/opt/forum-monitor/data/config.json`。你可以通过菜单 `9. edit` 修改，也可以手动编辑。

| 字段 | 说明 |
| :--- | :--- |
| `pushplus_token` | Pushplus 的 Token (留空不启用) |
| `telegram_bot_token` | Telegram Bot Token (BotFather 获取) |
| `telegram_chat_id` | 接收消息的 Chat ID (个人或频道 ID) |
| `gemini_api_key` | Google AI Studio 申请的 API Key |
| `ai_provider` | AI 提供商：`"gemini"` 或 `"workers"` |
| `frequency` | 轮询间隔（秒），建议 `>= 300`，太快可能触发 Cloudflare 盾 |
| `vip_threads` | 字符串数组，包含需要强制每轮扫描的帖子 URL |
| `monitored_roles` | 监控的角色列表，如 `["creator", "provider", "admin"]` |

-----

## 🖥️ 菜单功能详解

运行 `./ForumMonitor.sh` 即可唤出管理菜单：

### [基础管理]

  * **1. install**: 完整安装或重置环境。
  * **2. uninstall**: 停止服务并删除所有文件。
  * **3. update**: 热更新脚本代码（保留配置）。

### [服务控制]

  * **4-7. start/stop/restart/status**: Systemd 服务控制。
  * **8. logs**: 查看实时日志。**特色功能**：支持按任意键安全退出，自动清理后台日志进程，防止终端刷屏。

### [配置管理]

  * **9. edit**: 修改 Token 和 ID。
  * **10. ai-switch**: 在 Gemini 和 Cloudflare Workers AI 之间一键切换。
  * **11-12. frequency/threads**: 调整轮询频率和并发线程数。
  * **13. keepalive**: 添加 Crontab 任务，每5分钟检测一次服务状态。
  * **14. toggle-push**: **[v42+]** 实时开启/关闭 Pushplus 或 Telegram 推送，无需修改 Token。

### [监控规则]

  * **14-16**: 管理 VIP 专线链接、监控的角色（如楼主、商家）、以及指定监控的用户名。

### [功能测试]

  * **17. test-ai**: 测试 AI API 是否连通并能正常回复。
  * **18. test-push**: 发送一条**全真模拟**的优惠通知，包含完整排版，用于测试显示效果。
  * **20. repush**: 强制重新分析并推送数据库中最近 5 个活跃帖子（绕过去重逻辑）。

-----

## 🤖 AI 提示词 (System Prompts)

项目内置了两套精心调优的 Prompt（提示词），分别用于：

1.  **Thread Analysis (新帖分析)**：

      * 要求 AI 提取机房、配置、价格。
      * 要求 AI 翻译为中文。
      * 要求 AI 判断优缺点和适用人群。

2.  **Comment Filtering (回复过滤)**：

      * 要求 AI 扮演“福利分析师”。
      * 只有当回复包含 **补货、降价、优惠码、赠送** 等实质内容时才提取。
      * 纯表情、"Thank you"、"Nice" 等内容会被 AI 标记为 `FALSE` 并直接丢弃。

-----

## 📝 更新日志

  * **v53/54 (Current)**:
      * 修复了日志查看器退出时的崩溃问题。
      * 优化了 Telegram 消息排版，增加了 `[新帖]` / `[Repush]` / `[TEST]` 等醒目标题前缀。
      * 增强了 `repush` 功能，允许强制推送已存在的帖子。
  * **v50-52**:
      * 引入 **单例锁 (Singleton Lock)** 和 **自愈机制 (Self-Healing)**，彻底解决了后台双重进程导致的日志重复和资源浪费问题。
  * **v40-49**:
      * 增加了推送通道独立开关。
      * 恢复了彩色的日志输出，优化了视觉体验。

-----

## ⚠️ 免责声明

本工具仅供学习和技术研究使用。请勿将轮询频率设置过高，以免对目标网站造成压力或导致 IP 被封禁。开发者不对使用本工具产生的任何后果负责。

