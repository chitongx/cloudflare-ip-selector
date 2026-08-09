#!/usr/bin/env bash
# ============================================================
#  Cloudflare 优选 IP 一键测速 + 自动更新 hosts
#  基于 XIU2/CloudflareSpeedTest (https://github.com/XIU2/CloudflareSpeedTest)
#  用法:
#    ./cfst-hosts.sh           # 测速 + 预览将要写入的 hosts 记录（不真正修改）
#    ./cfst-hosts.sh --apply   # 测速 + 真正写入 /etc/hosts（需要 sudo 密码）
#    ./cfst-hosts.sh --full    # 测速 + 写入 + 刷新 DNS 缓存
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"

# ==================== 配置区 ====================
# 要加速的域名（按需增删；只建议加确实走 Cloudflare CDN 的域名）
DOMAINS=(
  github.com
  api.github.com
  raw.githubusercontent.com
  codeload.github.com
  objects.githubusercontent.com
  github.githubassets.com
  githubstatus.com
)
# CFST 测速参数（默认 -dd 纯延迟测速，速度快且不依赖下载测速地址）
# 注意: 官方默认测速地址 cf.xiu2.xyz 已失效(403)，改用 speed.cloudflare.com（响应头自带 cf-meta-colo 地区码）
# 如需下载测速，改为: (-url "https://speed.cloudflare.com/__down?bytes=100000" -sl 1 -dn 5 -o result.csv)
CFST_ARGS=(-dd -tl 300 -tlr 0.2 -n 100 -o result.csv)
# ==================== 配置区结束 ====================

MODE="${1:-preview}"   # preview | apply | full

# ---------- 1. 测速 ----------
echo "==> [1/3] 开始 Cloudflare 测速（参数: ${CFST_ARGS[*]}）..."
if ! ./cfst "${CFST_ARGS[@]}"; then
  echo "!! CFST 运行失败" >&2; exit 1
fi

# ---------- 2. 解析最快 IP ----------
if [[ ! -f result.csv ]]; then
  echo "!! 没有生成 result.csv，可能一个可用 IP 都没测到" >&2; exit 1
fi
# 去掉可能的 BOM，取第 2 行第 1 列（第一行是表头）
BESTIP=$(sed '1d;2q' result.csv | sed 's/^\xef\xbb\xbf//' | awk -F, 'NR==1{print $1}' | tr -d ' ')
if [[ -z "$BESTIP" ]]; then
  echo "!! 测速结果为空，没有找到可用 IP" >&2; exit 1
fi
echo "==> [2/3] 最快 IP: $BESTIP  （$(awk -F, 'NR==2{print "延迟 "$5"ms 速度 "$6"MB/s 地区 "$7}' result.csv)）"

# ---------- 3. 更新 hosts ----------
if [[ "$MODE" == "preview" ]]; then
  echo "==> [3/3] 预览模式，将写入以下记录（--apply 才会真正生效）:"
  for d in "${DOMAINS[@]}"; do printf "    %-35s %s\n" "$BESTIP" "$d"; done
  exit 0
fi

echo "==> [3/3] 备份 /etc/hosts -> /etc/hosts.bak"
sudo cp /etc/hosts /etc/hosts.bak

echo "==> 清理这些域名的旧记录并写入新 IP..."
for d in "${DOMAINS[@]}"; do
  # 删除 hosts 中该域名的所有旧记录（行尾精确匹配，不影响同后缀域名）
  sudo sed -i '' "/[[:space:]]${d//./\\.}[[:space:]]*$/d" /etc/hosts
  echo "${BESTIP} ${d}" | sudo tee -a /etc/hosts > /dev/null
done

if [[ "$MODE" == "full" ]]; then
  echo "==> 刷新 DNS 缓存..."
  sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder 2>/dev/null || true
fi
echo "==> 完成！验证一下:"
for d in "${DOMAINS[@]}"; do
  printf "    %-35s -> %s\n" "$d" "$(dig +short "$d" | head -1)"
done
