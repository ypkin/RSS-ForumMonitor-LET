

-----

# 🚀 ForumMonitor - LowEndTalk AI 智能监控 (Gemini Edition)

> **基于 Google Gemini AI 的 VPS 论坛高信噪比监控系统**
>
> *AI 意图识别 | 自动翻译 | 补货直达 | 福利/抽奖捕捉 | 双通道推送*

**ForumMonitor** 是一个高度定制化的 LowEndTalk 论坛监控脚本。与传统的关键词监控不同，它引入了 **Google Gemini AI** 进行语义分析，不仅能识别商家的“补货”、“降价”意图，还能精准捕捉 **“赠送余额”、“抽奖 (Giveaway/Raffle)”** 等福利信息，并自动过滤掉无关的水贴。

-----

## ✨ 核心特性 (Key Features)

  * **🧠 AI 驱动分析**: 使用 **Google Gemini 2.5 Flash Lite** 模型，将英文内容自动翻译为中文摘要，并提取关键信息（套餐/价格/优惠码/截止时间）。
  * **🎁 全方位监控**:
      * **销售 (Sales)**: 补货、闪购、降价、新套餐。
      * **福利 (Perks)**: 抽奖 (Raffle)、赠送 (Giveaway)、免费试用、送余额。
  * **👥 精细化角色过滤**:
      * 支持监控：**楼主 (Creator)**、**认证商家 (Provider)**、**Top Host**、**Host Rep**、**管理员 (Admin)**。
      * **指定用户监控**: 支持添加特定的大佬/红人 ID (Target Users)，无论其是否有商家身份，均强制监控。
  * **📢 双通道推送**:
      * **Telegram**: 支持长消息自动分段 (Auto-Chunking)，完美修复长文发送失败问题；支持 HTML 渲染。
      * **Pushplus**: 微信/企业微信通道支持。
  * **🎨 视觉增强**: 推送标题带 Emoji 区分：
      * 🟢 **[新帖]**：新发布的促销/活动。
      * 🔵 **[楼主]**：楼主本人的回复。
      * 🔴 **[插播]**：其他商家或指定大佬的回复。
  * **🛡️ 智能防风控**: 集成 `CloudScraper`，模拟真实浏览器指纹，有效绕过 Cloudflare 5秒盾。
  * **📉 智能局部扫描**: 针对几百页的“传家宝”神帖，仅智能回溯扫描 **最后 3 页**，既防漏抓又低负载。
  * **⚡ 精准直达**: 推送链接采用 `comment/{id}/#Comment_{id}` 锚点格式，点击通知直接跳转到具体楼层。

-----

## 🛠️ 运行逻辑

脚本采用 **Bash 管理 + Python 核心** 的架构，运行逻辑如下：

1.  **全域发现**:
      * **RSS 快速扫描** (多线程): 秒级发现新发布的帖子。
      * **双板块兜底** (单线程): 轮询 `Offers` 和 `Announcements` 板块，防止 RSS 漏抓。
      * **VIP 专线**: 强制监控指定的“万楼大厦” (Megathread)，无视发布时间限制。
2.  **新帖处理**:
      * Gemini AI 翻译全文 → 提取高性价比套餐 → 生成中文摘要 → 🟢 推送。
3.  **回复/补货监控**:
      * 锁定活跃帖子 → 计算最大页码 → 倒序扫描最后 3 页。
      * **身份校验**: 是商家? 是管理? 是指定的大佬?
      * **AI 裁判**: 内容是“卖货”还是“送福利”？(是 → 🔵/🔴 推送; 否 → 忽略)。

-----

## 📥 安装与部署

### 前置要求

  * 一台 Linux VPS (推荐 Debian 11/12 或 Ubuntu 20.04+)。
  * **Google Gemini API Key** ([获取地址](https://aistudio.google.com/app/apikey))。
  * **Telegram Bot Token & Chat ID** (可选，推荐)。
  * **Pushplus Token** (可选)。

### 一键安装

```bash
# 下载脚本
wget -O ForumMonitor.sh https://raw.githubusercontent.com/ypkin/RSS-ForumMonitor-LET/refs/heads/ForumMonitor-with-gemini/ForumMonitor.sh

# 添加执行权限
chmod +x ForumMonitor.sh

# 运行安装向导
./ForumMonitor.sh
```

进入菜单后，选择 `1. install`，根据提示输入 API Key 即可完成部署。

-----

## 🖥️ 命令菜单

安装完成后，直接输入 `fm` 或 `./ForumMonitor.sh` 即可唤出管理菜单：

| 选项 | 命令 | 描述 |
| :--- | :--- | :--- |
| **1** | `install` | 安装依赖、MongoDB 并初始化配置 |
| **3** | `update` | 在线更新脚本到最新版本 |
| **6** | `restart` | 重启后台服务 |
| **8** | `edit` | 修改 API Key、Token 或 AI 模型 |
| **9** | `frequency` | 修改轮询间隔 (默认 600秒) |
| **11** | `vip` | **VIP 专线管理** (强制监控特定神帖) |
| **12** | `roles` | **角色管理** (开关 Provider/Admin/Other 等监控) |
| **14** | `logs` | 查看实时运行日志 |
| **15** | `test-ai` | 测试 Gemini API 连通性 |
| **16** | `test-push`| 发送测试消息到所有通道 |
| **19** | `users` | **指定用户管理** (添加特定的大佬 ID) |

-----

## 🔔 推送示例

### 1\. 新帖推送

> **🟢 [新帖] HostUS Black Friday Special**
>
>   * **AI 甄选**: 1GB Ryzen KVM ($15/Year) - 性价比极高。
>   * **VPS 列表**: ...
>   * **优缺点分析**: ...

### 2\. 商家补货

> **🔵 [HostUS] 楼主新回复**
>
>   * **🎁 内容**: 1GB 传家宝套餐已补货 50 台。
>   * **🏷️ 代码**: `BF2025`
>   * **🔗 链接**: [👉 查看回复 (直达楼层)]

### 3\. 福利/抽奖

> **🔴 [RackNerd] ⚡插播(dustinc)**
>
>   * **🎁 内容**: 评论本帖抽取 3 位用户赠送 $50 余额。
>   * **🏷️ 规则**: 包含 "I love RN" 即可参与。
>   * **📝 备注**: 24小时后开奖。
>   * **🔗 链接**: [👉 查看回复 (直达楼层)]

-----

## 📂 文件结构

  * `/opt/forum-monitor/` - 程序主目录
      * `core.py` - Python 核心逻辑 (爬虫/AI/数据库)
      * `send.py` - 消息推送模块 (支持 TG 分段)
      * `data/config.json` - 用户配置文件
      * `data/stats.json` - 统计数据
      * `venv/` - Python 虚拟环境

-----

## ⚠️ 免责声明

本脚本仅供学习交流使用。请勿将扫描频率设置过高（建议不低于 60秒），以免对目标网站造成压力。使用本脚本产生的任何后果由使用者自行承担。
