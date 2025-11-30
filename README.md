

# 🚀 ForumMonitor - LowEndTalk AI 监控助手

**ForumMonitor** 是一个专为 **LowEndTalk (LET)** 论坛设计的高级监控工具。它结合了传统的 RSS 轮询与现代 **AI 技术 (Google Gemini / Cloudflare Workers AI)**，能够自动抓取最新的 VPS 优惠信息，生成中文摘要，并智能筛选高价值回复（如补货、降价、抽奖）。

支持 **Telegram (Bot/Channel)** 和 **Pushplus** 实时推送。

-----

## ✨ 核心功能

  * **🤖 AI 智能摘要**: 自动识别新发布的 Offer 帖，提取关键配置（CPU/内存/线路/价格），并将内容翻译汇总为中文摘要。
  * **🧹 智能评论过滤**: 监控指定帖子（VIP模式）或特定用户。AI 会分析每一条回复，**自动过滤掉灌水内容**，仅推送 **补货 (Restock)**、**降价 (Price Drop)** 或 **抽奖赠送 (Giveaway)** 等高价值信息。
  * **📢 多渠道推送**:
      * **Telegram**: 支持发送给个人或 **频道 (Channel)**，消息排版精美。
      * **Pushplus**: 支持微信推送。
  * **🛡️ 强力过盾**: 内置 `cloudscraper` 和浏览器模拟技术，有效通过 Cloudflare 5秒盾和 WAF 拦截。
  * **👥 角色监控**: 支持按角色监控（管理员、认证商家、Top Host 等），不错过大佬发言。
  * **🛠️ 全能管理菜单**: 提供 CLI 交互菜单，支持一键安装、更新、修改配置、查看日志和切换 AI 引擎。

-----

## 🛠️ 安装与使用

### 环境要求

  * **OS**: Debian / Ubuntu (推荐 Debian 11/12)
  * **User**: Root 用户
  * **Dependency**: 脚本会自动安装 Python3, MongoDB, Node.js 等依赖。

### 🚀 一键安装/运行

下载脚本并赋予执行权限：

```bash
wget -O ForumMonitor.sh https://raw.githubusercontent.com/ypkin/RSS-ForumMonitor-LET/refs/heads/ForumMonitor-with-gemini/ForumMonitor.sh && chmod +x ForumMonitor.sh && ./ForumMonitor.sh
```

*(注：如果你的脚本在本地，请直接运行 `./ForumMonitor.sh`)*

首次运行会进入安装向导，按提示输入 API Key 即可。

-----

## ⚙️ 配置说明

安装过程中或通过菜单 `9. edit` 修改配置。

### 1\. 🤖 AI 引擎设置 (必须)

支持两种 AI 后端，建议首选 **Gemini** (免费且速度快)。

  * **Google Gemini**:
      * API Key 申请: [Google AI Studio](https://aistudio.google.com/)
      * 模型: 默认使用 `gemini-2.0-flash-lite` (速度极快)。
  * **Cloudflare Workers AI**:
      * 需要填写 `Account ID` 和 `API Token`。
      * 模型: 默认使用 `@cf/meta/llama-3.1-8b-instruct`。

### 2\. 📢 Telegram 推送设置

  * **Bot Token**: 向 [@BotFather](https://t.me/BotFather) 申请。
  * **Chat ID / Channel ID**:
      * **发送给个人**: 直接填写你的数字 ID (通过 `@userinfobot` 获取)。
      * **发送给频道 (Channel)**:
        1.  将机器人拉入频道并设为 **管理员 (Admin)**。
        2.  填写频道 ID，**必须保留 `-100` 前缀** (例如: `-100123456789`)。

### 3\. 📝 监控规则 (进阶)

  * **VIP 专线监控**: 在菜单中选择 `15. vip` 添加特定帖子的 URL。脚本会高频扫描该帖子的新回复（适合监控热门商家的活动贴）。
  * **监控角色**: 在菜单中选择 `16. roles`，可开关对“认证商家”、“管理员”等特定用户组的监控。

-----

## 🖥️ 菜单功能详解

运行 `./ForumMonitor.sh` 即可唤出管理菜单：

| 选项 | 命令 | 说明 |
| :--- | :--- | :--- |
| **1** | `install` | 执行初始化安装，部署 Python 环境和数据库 |
| **4/5/6** | `start/stop/restart` | 启动、停止或重启后台服务 |
| **8** | `logs` | **实时查看运行日志** (按 `0` 返回，`Ctrl+C` 退出) |
| **9** | `edit` | 修改 Token、ID 和 Key 等核心配置 |
| **10** | `ai-switch` | 在 Gemini 和 Cloudflare AI 之间快速切换 |
| **14** | `toggle-push` | 快速开启/关闭某个推送通道 |
| **15** | `vip` | 管理重点监控的帖子列表 (Add/Del) |
| **21** | `repush` | 手动触发 AI 重新摘要并推送最近的帖子 (调试用) |

-----

## 📷 效果预览

### 新帖通知 (New Thread)

> ## **🟢 [新帖] RackNerd Black Friday 2025** 👤 racknerd\_dustin | 🕒 10:25 | 🤖 gemini-2.0-flash-lite
>
> **🏆 AI 甄选 (高性价比)：**
> • **1GB KVM VPS** ($10.18/yr)：年度最低价，适合建站。
>
> ## **VPS 列表：** • **2GB Plan** → $15.88/yr [下单地址] └ 2 Core / 2GB / 30GB NVMe / 2.5Gbps ...
>
> 👉 查看原帖 (Source)

### 高价值回复通知 (Smart Reply Filter)

> ## **🔴 [HostHatch] 插播(HostHatch)** 📌 HostHatch Black Friday deals 👤 HostHatch | 🕒 11:30 | 🤖 gemini-2.0-flash-lite
>
> ## **🎁 内容:** 刚刚补货了 50 台香港存储型 VPS。 **🔗 链接:** [链接地址] **📝 备注:** 手慢无。
>
> 👉 查看回复 (Go to Comment)

-----

## 📂 目录结构

  * `/opt/forum-monitor/`: 项目主目录
      * `core.py`: 核心监控逻辑
      * `send.py`: 推送模块
      * `data/config.json`: 配置文件
      * `venv/`: Python 虚拟环境

-----

## ⚠️ 免责声明

本工具仅供学习和个人辅助使用。请勿用于通过高频请求恶意攻击论坛。请合理设置 `config.json` 中的 `frequency` (轮询间隔) 和 `max_workers` (线程数)，以免 IP 被目标网站封禁。

-----

