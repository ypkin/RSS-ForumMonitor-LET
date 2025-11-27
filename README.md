
-----

# 🤖 ForumMonitor: Cloudflare AI 驱动的 VPS 优惠信息监控与推送服务

`ForumMonitor` 是一个专为 VPS (Virtual Private Server) 爱好者设计的监控服务。它能够实时抓取特定论坛（默认为 LowEndTalk/LET）的促销帖子，利用 Cloudflare Workers AI 自动生成结构化的中文摘要、套餐推荐和优缺点分析，并通过 Pushplus 实时推送到您的微信、钉钉等通知渠道。

该项目由一个 Shell 管理脚本 (`ForumMonitor.sh`) 和 Python 核心代码组成，专注于 Debian 系统上的快速部署和稳定运行。

## ✨ 主要特性

  * **实时监控与 AI 摘要:** 监控 LET/Offers RSS 源，并利用 Cloudflare AI (Llama-3) 自动翻译和结构化摘要。
  * **富文本推送 (Pushplus):** 推送内容包含 **AI 结构化分析**、**下单超链接**、**简要概括**和**合适套餐推荐**。
  * **全自动部署:** 一键安装所有依赖 (Python, MongoDB, systemd 服务) 和自动配置。
  * **服务自愈 (Keepalive):** 基于 Crontab 和心跳文件 (`heartbeat.txt`) 的自动检测和重启机制。
  * **完整的管理菜单:** 通过快捷命令 `fm` 即可进行启动、停止、配置、日志查看等操作。

## ⚙️ 部署要求

  * 操作系统: **Debian 11/12** (推荐)。
  * 权限: **Root 权限** (`sudo su` 或直接以 root 登录)。
  * 依赖: Python 3, MongoDB (脚本自动安装), `jq`, `curl` 等。

## 🚀 快速部署与安装

### 步骤 1: 下载管理脚本

```bash
# 下载脚本
curl -Lo ForumMonitor.sh https://raw.githubusercontent.com/ypkin/RSS-ForumMonitor-LET/refs/heads/ForumMonitor-with-gemini/ForumMonitor.sh
# 赋予执行权限
chmod +x ForumMonitor.sh
```

### 步骤 2: 获取用户参数

在运行安装命令前，您需要准备以下三个密钥：

| 参数 | 作用 | 获取方法/说明 |
| :--- | :--- | :--- |
| **Pushplus Token** | 消息推送服务的唯一密钥。 | 登录 [Pushplus 官网](http://www.pushplus.plus/) 获取。 |
| **Cloudflare API Token** | 用于调用 Workers AI 服务的密钥。 | 登录 Cloudflare -\> **我的个人资料** -\> **API 令牌**。需要授予 **Workers AI** 的 **编辑** 权限。 |
| **Cloudflare Account ID** | Workers AI 服务的账户标识符。 | 登录 Cloudflare -\> **Workers 和 Pages** 概览页面顶部获取。 |

### 步骤 3: 运行安装命令

执行安装脚本。脚本将自动安装 MongoDB、Python 环境、创建服务文件并提示您输入上述参数。

```bash
 ./ForumMonitor.sh

```

在安装过程中，按照提示输入您的 `Pushplus Token`、`CF Token` 和 `CF Account ID`。服务安装成功后将自动启动。

## 📋 管理命令 (快捷方式: `fm`)

安装完成后，脚本会自动创建 `/usr/local/bin/fm` 快捷方式。您可以在终端中直接使用 `fm` 命令管理服务。

| 编号 | 命令 | 描述 |
| :---: | :--- | :--- |
| **`fm`** | `fm` | 显示状态仪表盘和主菜单 (默认操作)。 |
| **1** | `fm install` | 重新安装/重置服务（包括环境和依赖）。 |
| **2** | `fm uninstall` | **彻底卸载**服务、依赖和所有数据。 |
| **3** | `fm update` | 从 GitHub 更新此管理脚本到最新版本。 |
| **6** | `fm restart` | 重启核心监控服务。 |
| **7** | `fm keepalive` | **开启自动保活** (通过 Crontab 定时检查和重启)。 |
| **8** | `fm edit` | 交互式地修改 Pushplus/CF API 密钥。 |
| **9** | `fm frequency` | 修改脚本遍历论坛的间隔时间（秒，默认 600 秒）。 |
| **10** | `fm status` | 查看 systemd 服务详细运行状态和内部心跳。 |
| **11** | `fm logs` | 实时查看脚本日志（`journalctl -f`）。 |
| **13** | `fm test-push` | 发送一条模拟的 AI 摘要消息到您的 Pushplus 渠道。 |

## 💡 常见问题与提示

### 1\. 如何确保服务稳定运行?

务必运行 `fm keepalive` (`fm 7`) 命令，这将在 Crontab 中添加一个每 5 分钟执行的检查任务，以确保服务进程意外退出或冻结时能被自动拉起。

### 2\. 如何修改 AI 摘要的格式?

AI 摘要的格式由配置文件 `data/config.json` 中的 `thread_prompt` 变量控制。你可以通过 SSH 编辑此文件，然后运行 `fm restart` 使更改生效。

### 3\. 如何调试推送?

使用 `fm test-push` (`fm 13`) 命令可以立即发送一个测试通知，确认您的 Pushplus Token 配置是否正确，以及消息格式是否符合预期。

### 4\. 为什么看不到日志颜色?

脚本默认使用 `journalctl -u ... --output cat` 尝试强制显示颜色，以获得更好的阅读体验。如果仍无颜色，可能是您的终端环境不支持或已运行的 `fm logs` 命令没有设置 `TERM=xterm-256color`（服务文件中已设置）。
