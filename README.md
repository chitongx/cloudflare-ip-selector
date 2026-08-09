# Cloudflare 优选 IP 自动测速与更新工具

> 按国家/地区筛选 Cloudflare 最优 IP，自动补测下载速度，输出可直接导入代理工具的优选列表，并支持一键更新 hosts 加速 GitHub 访问。

![License](https://img.shields.io/badge/license-MIT-green) ![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue) ![Shell](https://img.shields.io/badge/shell-bash-yellow)

基于 [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)（CFST）二次封装：解决它「全量测速结果冗长、无法按地区快速提取、无下载速度」的使用痛点，输出**开箱即用的优选 IP 列表**。

---

## ✨ 功能特性

- 🌏 **按地区筛选**：香港、东京、新加坡、洛杉矶、法兰克福等 10+ 个地区码，每个地区输出 Top N 最优 IP
- ⚡ **延迟 + 速度双指标**：先 HTTPing 并发测延迟（6000+ IP，约 3 分钟），再对入选 IP 并发实测下载速度
- 📋 **优选列表格式输出**：`IP:端口#地区码 运营商优选[延迟ms 速度Mbps]`，可直接导入代理工具 / 优选 IP 插件
- 🚀 **一键加速 GitHub**：`cfst-hosts.sh --apply` 自动将 GitHub 全家桶域名解析到最优 IP（自动备份，可一键还原）
- 🤖 **每日自动更新**：配合 cron / 定时任务，每天自动测速并推送最新最优 IP
- 📁 **结果归档**：桌面文件夹自动生成汇总、分地区、全量 CSV 三份结果

## 📊 输出示例

```
Cloudflare 优选 IP（2026-08-10）
============================================================
# SIN（新加坡）:
104.18.36.149:443#SIN 电信优选[78ms 12.34Mbps]
162.159.34.63:443#SIN 电信优选[78ms 4.92Mbps]
104.18.40.98:443#SIN 电信优选[81ms 11.46Mbps]
104.18.39.52:443#SIN 电信优选[83ms 10.52Mbps]
# NRT（东京）:
172.64.52.141:443#NRT 电信优选[87ms 10.44Mbps]
108.162.198.71:443#NRT 电信优选[94ms 7.28Mbps]
...
```

每行格式：`IP:端口#地区码 备注标签[平均延迟ms 下载速度Mbps]`

## 🚀 快速开始

### 一键安装

```bash
git clone https://github.com/chitongx/cloudflare-ip-selector.git
cd cloudflare-ip-selector
./install.sh        # 自动下载对应平台的 CFST 二进制（macOS/Linux）
# 国内网络加速: MIRROR='https://ghfast.top/' ./install.sh

./cfst-region.sh    # 开始测速，约 3 分钟
```

### 手动安装

1. 下载 [CloudflareSpeedTest Releases](https://github.com/XIU2/CloudflareSpeedTest/releases) 对应平台二进制，重命名为 `cfst` 放入本目录
2. 确保系统有 `curl`、`python3`（macOS / 主流 Linux 均自带）
3. `chmod +x cfst cfst-region.sh cfst-hosts.sh`

## 📖 命令用法

### `cfst-region.sh` — 按地区筛选最优 IP

```bash
./cfst-region.sh                          # 默认: 10 个常用地区 × 每地区 Top4
./cfst-region.sh "HKG,SIN,NRT"            # 只测指定地区
./cfst-region.sh "HKG,SIN" 6              # 指定地区 + 每地区取 6 个
./cfst-region.sh "SIN,NRT" 4 "联通优选"    # 自定义运营商标签（默认"电信优选"）
```

运行后自动更新 `~/Desktop/Cloudflare优选IP/` 文件夹：

| 文件 | 内容 |
|---|---|
| `最优IP-汇总.txt` | 全部地区优选列表（带日期） |
| `SIN-新加坡.txt` 等 | 每个地区独立文件 |
| `全部结果.csv` | 本次全量测速明细（含地区码） |

### 🛡️ IP 纯净度检测（免费，零成本）

脚本对每个候选 IP 自动检测纯净度并标注：**机房/非机房**（proxycheck.io）+ **原生/广播 IP**（ipinfo.io anycast），可选启用**风控值评分**（AbuseIPDB）。

**启用风控值（可选）**：去 [AbuseIPDB](https://www.abuseipdb.com/register) 免费注册 API Key（每天 1000 次查询，本项目每天仅查 40 个 IP），填入脚本顶部或环境变量：

```bash
# 脚本配置区（cfst-region.sh 顶部）
ABUSEIPDB_KEY=""     # 填入免费注册的 key，才有风控值
RISK_MAX=60          # 风控值上限(%)，超过自动过滤；设 100 则不过滤

# 或运行时传入
ABUSEIPDB_KEY=xxxx ./cfst-region.sh
```

启用后输出示例（行尾追加纯净度标注）：

```
# SIN（新加坡）:
104.18.36.149:443#SIN 电信优选[78ms 12.34Mbps] 风控0% 机房IP 广播IP
162.159.34.63:443#SIN 电信优选[78ms 4.92Mbps] 风控25% 机房IP 广播IP
  （风控>60% 已过滤 1 个: 104.18.40.98[风控75%]）
```

> 未配置 AbuseIPDB Key 时仍标注 机房/广播（proxycheck + ipinfo 免费接口），仅缺少风控值。
> 说明：Cloudflare anycast IP 均为机房属性（广播 IP），纯净度主要看风控值。

### `cfst-hosts.sh` — 一键更新 hosts 加速 GitHub

```bash
./cfst-hosts.sh           # 预览将要写入的记录（安全模式）
./cfst-hosts.sh --apply   # 真正写入 /etc/hosts（自动备份到 /etc/hosts.bak）
./cfst-hosts.sh --full    # 写入 + 刷新 DNS 缓存
```

默认加速域名：`github.com`、`api.github.com`、`raw.githubusercontent.com`、`codeload.github.com`、`objects.githubusercontent.com`、`github.githubassets.com`、`githubstatus.com`（脚本顶部 `DOMAINS` 数组可自定义）。

**还原 hosts**：`sudo cp /etc/hosts.bak /etc/hosts`

## 🤖 每日自动更新

### macOS（launchd）

```bash
mkdir -p ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/com.cloudflare.ipselector.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.cloudflare.ipselector</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>/Users/你的用户名/cloudflare-ip-selector/cfst-region.sh</string></array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>8</integer><key>Minute</key><integer>0</integer></dict>
</dict></plist>
EOF
launchctl load ~/Library/LaunchAgents/com.cloudflare.ipselector.plist
```

### Linux（crontab）

```bash
crontab -e
# 每天 8:00 运行
0 8 * * * /bin/bash /path/to/cloudflare-ip-selector/cfst-region.sh >> /tmp/cfst-region.log 2>&1
```

## ❓ 常见问题

**Q: 为什么香港/台北/首尔经常测不到？**
A: Cloudflare 的 anycast IP 段中，HKG/TPE/ICN 等亚洲小众地区占比极低（<1%），随机抽样测不到属正常现象。国内用户建议优先使用新加坡（SIN，约 78ms）和东京（NRT，约 95ms）。

**Q: 测速时需要注意什么？**
A: 测速前请**关闭代理软件**，否则平均延迟会显示 0.xx 导致结果失真；路由器上运行同理。开机后第一次测速延迟会偏高，属正常现象。

**Q: 下载速度为 0 怎么办？**
A: 本脚本默认使用 `speed.cloudflare.com` 作为测速地址（官方默认地址 `cf.xiu2.xyz` 已失效返回 403）。若仍为 0，可检查网络或改用 `-dd` 纯延迟模式（`cfst-region.sh` 脚本内 `CFST_ARGS` 调整）。

**Q: 每次结果都不一样？**
A: 正常。CFST 在每个 IP 段随机抽样，且 Cloudflare 的 anycast 路由动态变化，建议每日定时更新保持最优。

## ⚠️ 注意事项

- Cloudflare CDN 官方**明文禁止代理用途**（[讨论 #382](https://github.com/XIU2/CloudflareSpeedTest/discussions/382)），请勿将本工具用于搭建代理，风险自担
- 本工具仅适用于网站加速场景，不支持 WARP 的 UDP 优选
- 修改 hosts 前脚本会自动备份，异常时可通过备份文件还原

## 🙏 致谢

- [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) — 核心测速引擎
- [Cloudflare](https://www.cloudflare.com/) — 全球 CDN 网络

## 📄 License

[MIT](LICENSE)
