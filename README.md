-----

# 🚀 ForumMonitor - Intelligent LowEndTalk Monitor

> **基于 Google Gemini AI 的 LowEndTalk 论坛智能监控系统**
>
> *高信噪比 | AI 意图识别 | 自动翻译 | 补货直达 | 商家身份过滤*

**ForumMonitor** 是一个高度定制化的 VPS 优惠监控脚本。它不同于传统的关键词监控，而是引入了 **Google Gemini AI** 进行语义分析，能够精准识别商家的“补货”、“降价”、“闪购”等销售意图，并自动过滤掉无关的水贴和客套话。

-----

## ✨ 核心特性 (Key Features)

  * **🧠 AI 驱动分析**: 使用 Google Gemini 2.5 Flash Lite 模型，将英文帖子自动翻译为中文摘要，并提取配置、价格等关键信息。
  * **🛡️ 智能防风控 (Anti-WAF)**: 集成 `CloudScraper`，模拟真实浏览器指纹，有效绕过 Cloudflare 5秒盾和人机验证。
  * **🎯 高精准回复监控**:
      * **身份过滤**: 仅监控 **楼主 (Creator)**、**认证商家 (Provider)** 和 **Top Host** 的回复。
      * **意图识别**: AI 自动判断回复内容是否包含“补货”、“加库存”、“新优惠码”等信息，过滤掉 "Thank you" 等无效回复。
  * **📉 智能局部扫描**: 针对几百页的“传家宝”神帖，仅智能回溯扫描 **最后 3 页**，既防止漏掉翻页时的补货信息，又极大降低请求频率。
  * **⚡ 精准楼层直达**: 推送链接采用 `comment/{id}/#Comment_{id}` 格式，点击通知直接跳转到具体楼层，方便抢购。
  * **📱 增强型推送**:
      * 支持 **Pushplus** HTML 格式推送。
      * 动态标题：区分 `[商家] 楼主新回复` 和 `[商家] ⚡商家插播`。
      * 自带高亮“下单地址”按钮。

-----

## 🛠️ 运行逻辑 (How it Works)

脚本采用 **Bash 管理 + Python 核心** 的架构，运行逻辑如下：

1.  **双重发现机制**:
      * **RSS 快速扫描** (多线程): 每 10 分钟并发检查 RSS Feed，秒级发现新帖。
      * **列表页兜底** (单线程): 模拟浏览器访问 HTML 列表页，防止 RSS 延迟或漏抓。
2.  **新帖处理**:
      * Gemini AI 翻译全文 → 提取高性价比套餐 → 生成中文摘要 → 推送通知。
3.  **回复/补货监控**:
      * 锁定活跃帖子 → 计算最大页码 → 倒序扫描最后 3 页。
      * **身份校验**: 回复人是否为 Creator / Provider / Top Host？
      * **AI 裁判**: 内容是否涉及销售行为？(是 -\> 推送; 否 -\> 忽略)。

-----

## 📥 安装与部署 (Installation)

### 前置要求

  * 一台 Linux VPS (推荐 Debian 11/12 或 Ubuntu 20.04+)。
  * **Google Gemini API Key** ([获取地址](https://aistudio.google.com/app/apikey))。
  * **Pushplus Token** ([获取地址](https://www.pushplus.plus/))。

### 一键安装

```bash
# 下载脚本
curl -Lo ForumMonitor.sh https://raw.githubusercontent.com/ypkin/RSS-ForumMonitor-LET/refs/heads/ForumMonitor-with-gemini/ForumMonitor.sh 

# 添加执行权限
chmod +x ForumMonitor.sh

# 运行安装向导
./ForumMonitor.sh
```

进入菜单后，选择 `1. install`，根据提示输入 API Key 和 Token 即可完成部署。

-----

## 🖥️ 命令菜单 (Menu)

安装完成后，直接输入 `fm` 或 `./ForumMonitor.sh` 即可唤出管理菜单：

| 选项 | 命令 | 描述 |
| :--- | :--- | :--- |
| **1** | `install` | 安装依赖、MongoDB 并初始化配置 |
| **3** | `update` | 在线更新脚本到最新版本 |
| **6** | `restart` | 重启后台服务 |
| **8** | `edit` | 修改 API Key、模型名称或 Token |
| **9** | `frequency` | 修改轮询间隔 (默认 600秒) |
| **10** | `threads` | 修改 RSS 扫描并发线程数 |
| **12** | `logs` | 查看实时运行日志 |
| **15** | `history` | 查看最近成功的推送记录 (MongoDB) |
| **16** | `repush` | 手动触发最近活跃帖子的 AI 分析与推送 |

-----

## 🔔 推送示例 (Notifications)

### 1\. 新帖推送 (New Thread)

> **标题**: LET新促销: [HostUS] Black Friday Special Ryzen VPS
>
> **内容**:
>
>   * **AI 甄选**: 1GB Ryzen KVM ($15/Year) - 性价比极高。
>   * **VPS 列表**:
>       * Plan A → $15/yr [下单地址]
>       * Plan B → $25/yr [下单地址]
>   * **优缺点分析**: ...

### 2\. 商家补货 (Restock Reply)

> **标题**: [HostUS] ⚡商家(AlexanderM)插播
>
> **内容**:
>
>   * **AI 分析**: 检测到 1GB 套餐已补货，请尽快查看。
>   * **链接**: [👉 查看回复 (直达楼层)]

-----

## 📂 文件结构

  * `/opt/forum-monitor/` - 程序主目录
      * `core.py` - Python 核心逻辑 (爬虫/AI/数据库)
      * `send.py` - 消息推送模块
      * `data/config.json` - 配置文件
      * `data/stats.json` - 统计数据
      * `venv/` - Python 虚拟环境

-----

## 🤝 贡献与致谢

  * 项目逻辑基于 Discuz/Vanilla Forums 特性优化。
  * 感谢 **LowEndTalk** 社区。
  * AI 能力由 **Google Gemini** 提供。

-----

## ⚠️ 免责声明

本脚本仅供学习交流使用。请勿将扫描频率设置过高，以免对目标网站造成压力。使用本脚本产生的任何后果由使用者自行承担。
