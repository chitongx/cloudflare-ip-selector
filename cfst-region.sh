#!/usr/bin/env bash
# ============================================================
#  cfst-region.sh — Cloudflare 按地区筛选最优 IP，更新桌面文件夹
#
#  输出格式（优选 IP 列表格式，可喂给代理工具/优选插件）:
#    IP:端口#地区码 运营商优选[延迟ms 速度Mbps]
#    例: 172.64.42.181:443#SIN 电信优选[77ms 18.21Mbps]
#
#  用法:
#    ./cfst-region.sh                     # 默认常用地区，每地区 4 个
#    ./cfst-region.sh "HKG,SIN,NRT"       # 自定义地区列表
#    ./cfst-region.sh "HKG,SIN" 6         # 自定义地区 + 每地区取几个
#
#  输出:
#    1. 终端打印优选 IP 列表（每行一个）
#    2. 更新 ~/Desktop/Cloudflare优选IP/ 文件夹:
#       最优IP-汇总.txt / 全部结果.csv / 每个地区一个 txt
#
#  依赖: 同目录下的 cfst (CloudflareSpeedTest v2.3.5)，macOS 自带 curl
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"

CFST_BIN="./cfst"
# 注意: 官方默认测速地址 cf.xiu2.xyz 已失效(403)，用 speed.cloudflare.com（响应头带 cf-meta-colo 地区码）
URL="https://speed.cloudflare.com/__down?bytes=100000"
# 地区列表（IATA 机场码），可用: HKG NRT KHH TPE SIN ICN LAX SJC SEA FRA 等
COLOS="${1:-HKG,NRT,KHH,TPE,SIN,ICN,LAX,SJC,SEA,FRA}"
TOP_N="${2:-4}"
# 备注标签：按你的运营商改（电信优选/联通优选/移动优选/优选）
LABEL="${3:-电信优选}"
PORT=443
OUT_DIR="${HOME}/Desktop/Cloudflare优选IP"

# ===== ping0.cc 纯净度检测（可选）=====
# 在 ping0.cc 网站购买/获取 API Key 后填这里（或 export PING0_API_KEY=xxx）
# 有 key: 每个候选 IP 会检测 风控值/原生IP/机房IP，风控值 > RISK_MAX 的自动过滤
# 无 key: 跳过检测，输出保持原样
PING0_API_KEY="${PING0_API_KEY:-}"
RISK_MAX=60    # 风控值上限(%)，超过的 IP 视为不纯净自动过滤；设为 100 则不过滤
# ================================

mkdir -p "$OUT_DIR"

echo "==> [1/4] Cloudflare 地区延迟测速中（地区: ${COLOS}，每地区 Top ${TOP_N}）..."
if ! "$CFST_BIN" -httping -dd -url "$URL" -cfcolo "$COLOS" -tl 300 -tlr 0.2 -n 100 -o result.csv; then
  echo "!! CFST 测速失败" >&2
  exit 1
fi

echo "==> [2/4] 解析结果并为 Top IP 补测下载速度..."
COLOS="$COLOS" TOP_N="$TOP_N" LABEL="$LABEL" PORT="$PORT" OUT_DIR="$OUT_DIR" \
PING0_API_KEY="$PING0_API_KEY" RISK_MAX="$RISK_MAX" \
env -u PYTHONPATH python3 << 'PYEOF'
import csv, os, collections, datetime, subprocess
from concurrent.futures import ThreadPoolExecutor

colo_csv = os.environ["COLOS"]
top_n = int(os.environ["TOP_N"])
label = os.environ["LABEL"]
port = os.environ["PORT"]
out_dir = os.environ["OUT_DIR"]
ping0_key = os.environ.get("PING0_API_KEY", "")
risk_max = int(os.environ.get("RISK_MAX", "60"))
DL_URL = "https://speed.cloudflare.com/__down?bytes=2000000"

REGION_NAMES = {
    "HKG": "香港", "NRT": "东京", "KHH": "高雄", "TPE": "台北", "SIN": "新加坡",
    "ICN": "首尔", "LAX": "洛杉矶", "SJC": "圣何塞", "SEA": "西雅图", "FRA": "法兰克福",
}
requested = [c.strip().upper() for c in colo_csv.split(",") if c.strip()]

with open("result.csv", newline='', encoding='utf-8-sig') as f:
    rows = list(csv.DictReader(f))

groups = collections.defaultdict(list)
for r in rows:
    colo = (r.get("地区码") or "N/A").strip()
    try:
        lat = float(r.get("平均延迟") or 9999)
    except ValueError:
        lat = 9999
    groups[colo].append((lat, r))

def dl_mbps(ip):
    try:
        r = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{speed_download}",
             "--max-time", "8", "--resolve", f"speed.cloudflare.com:{port}:{ip}", DL_URL],
            capture_output=True, text=True, timeout=13)
        return float(r.stdout or 0) * 8 / 1_000_000
    except Exception:
        return 0.0

def ping0_check(ip):
    """调 ping0.cc 付费接口查纯净度，返回 (风控值%, 原生IP, 机房IP) 或 None（失败/无key）"""
    if not ping0_key:
        return None
    try:
        url = f"https://ping0.cc/apiloc/apikey({ping0_key})/ip({ip})"
        r = subprocess.run(["curl", "-s", "--max-time", "12", url],
                           capture_output=True, text=True, timeout=15)
        import json as _json
        d = _json.loads(r.stdout or "{}")
        if not d or "ip" not in d or "error" in d:
            return None
        risk = d.get("iprisk")
        risk = int(risk) if isinstance(risk, (int, float)) else None
        return {
            "risk": risk,                       # 风控值 %
            "native": bool(d.get("isnative")),  # 原生 IP?
            "idc": bool(d.get("isidc")),        # 机房 IP?
            "asn_type": str(d.get("asntype") or ""),
        }
    except Exception:
        return None

def fmt_purity(p):
    """格式化纯净度标注（两个维度分开）: 风控26% 机房IP 广播IP"""
    if not p or p["risk"] is None:
        return ""
    iptype = "机房IP" if p["idc"] else "非机房IP"
    native = "原生IP" if p["native"] else "广播IP"
    return f" 风控{p['risk']}% {iptype} {native}"

# 每个地区取 TopN，并并发补测下载速度 + 纯净度
picks = {}   # colo -> [(lat, ip, mbps, purity), ...]
jobs = []
for colo in requested:
    if colo in groups:
        top = sorted(groups[colo], key=lambda x: x[0])[:top_n]
        picks[colo] = [(lat, r["IP 地址"].strip(), 0.0, None) for lat, r in top]
        for lat, ip, _, _ in picks[colo]:
            jobs.append((colo, ip))

with ThreadPoolExecutor(max_workers=10) as ex:
    speeds = {ip: m for ip, m in zip([j[1] for j in jobs], ex.map(dl_mbps, [j[1] for j in jobs]))}
    purities = {ip: p for ip, p in zip([j[1] for j in jobs], ex.map(ping0_check, [j[1] for j in jobs]))}
for colo in picks:
    picks[colo] = [(lat, ip, speeds[ip], purities[ip]) for lat, ip, _, _ in picks[colo]]

date_str = datetime.date.today().strftime("%Y-%m-%d")
lines = [f"Cloudflare 优选 IP（{date_str}）", "=" * 60]
ping0_enabled = bool(ping0_key)

for colo in requested:
    name = REGION_NAMES.get(colo, colo)
    if colo not in picks:
        lines.append(f"# {colo}（{name}）: 本轮未测到可用 IP")
        continue
    # 按风控值过滤（仅当纯净度检测启用且拿到了风控值）
    kept, filtered = [], []
    for lat, ip, mbps, p in picks[colo]:
        if ping0_enabled and p and p["risk"] is not None and p["risk"] > risk_max:
            filtered.append((lat, ip, mbps, p))
        else:
            kept.append((lat, ip, mbps, p))
    lines.append(f"# {colo}（{name}）:")
    with open(os.path.join(out_dir, f"{colo}-{name}.txt"), "w", encoding="utf-8") as f:
        f.write(f"# {colo}（{name}）Cloudflare 优选 IP Top{len(kept)}（{date_str}）\n")
        for lat, ip, mbps, p in kept:
            line = f"{ip}:{port}#{colo} {label}[{lat:.0f}ms {mbps:.2f}Mbps]{fmt_purity(p)}"
            lines.append(line)
            f.write(line + "\n")
    if filtered:
        lines.append(f"  （风控>{risk_max}% 已过滤 {len(filtered)} 个: "
                     + ", ".join(f"{ip}[风控{p['risk']}%]" for _, ip, _, p in filtered) + "）")

with open(os.path.join(out_dir, "最优IP-汇总.txt"), "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")

with open(os.path.join(out_dir, "全部结果.csv"), "w", encoding="utf-8-sig", newline="") as f:
    w = csv.writer(f)
    w.writerow(["IP地址", "已发送", "已接收", "丢包率", "平均延迟(ms)", "下载速度(MB/s)", "地区码"])
    for r in rows:
        w.writerow([r["IP 地址"], r["已发送"], r["已接收"], r["丢包率"], r["平均延迟"], r["下载速度(MB/s)"], r["地区码"]])

print("\n".join(lines))
status = f"（ping0 纯净度检测: {'已启用，风控>'+str(risk_max)+'% 自动过滤' if ping0_enabled else '未启用，配置 PING0_API_KEY 后开启'}）"
print(f"\n✅ 已更新: {out_dir} {status}")
print("   备注标签: " + label + "（可改脚本第 3 个参数）")
PYEOF
echo "==> [3/4] 完成"
