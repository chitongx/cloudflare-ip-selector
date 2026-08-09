#!/usr/bin/env bash
# ============================================================
#  cfst-region.sh — Cloudflare 按地区筛选最优 IP，更新桌面文件夹
#
#  输出格式（优选 IP 列表格式，可喂给代理工具/优选插件）:
#    IP:端口#地区码 运营商优选[延迟ms 速度Mbps] [纯净度标注]
#    例: 172.64.42.181:443#SIN 电信优选[77ms 18.21Mbps] 风控26% 机房IP 广播IP
#
#  用法:
#    ./cfst-region.sh                     # 默认常用地区，每地区 4 个
#    ./cfst-region.sh "HKG,SIN,NRT"       # 自定义地区列表
#    ./cfst-region.sh "HKG,SIN" 6         # 自定义地区 + 每地区取几个
#
#  纯净度检测（免费方案）:
#    proxycheck.io（机房判断）+ ipinfo.io（广播IP判断）+ AbuseIPDB（风控分，可选）
#    配置 ABUSEIPDB_KEY 才有风控值；风控值 > RISK_MAX 的 IP 自动过滤
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

# ===== IP 纯净度检测（免费方案）=====
#  proxycheck.io（机房判断）+ ipinfo.io（anycast=广播IP）+ AbuseIPDB（风控分）
#  AbuseIPDB 免费注册 key: https://www.abuseipdb.com/register（每天1000次）
#  填了 ABUSEIPDB_KEY 才有「风控值」，不填则只标注 机房/广播
ABUSEIPDB_KEY="${ABUSEIPDB_KEY:-}"
RISK_MAX=60    # 风控值上限(%)，超过的 IP 视为不纯净自动过滤；设为 100 则不过滤
# ================================

mkdir -p "$OUT_DIR"

echo "==> [1/4] Cloudflare 地区延迟测速中（地区: ${COLOS}，每地区 Top ${TOP_N}）..."
if ! "$CFST_BIN" -httping -dd -url "$URL" -cfcolo "$COLOS" -tl 300 -tlr 0.2 -n 100 -o result.csv; then
  echo "!! CFST 测速失败" >&2
  exit 1
fi

echo "==> [2/4] 解析结果并为 Top IP 补测下载速度 + 纯净度..."
COLOS="$COLOS" TOP_N="$TOP_N" LABEL="$LABEL" PORT="$PORT" OUT_DIR="$OUT_DIR" \
ABUSEIPDB_KEY="$ABUSEIPDB_KEY" RISK_MAX="$RISK_MAX" \
env -u PYTHONPATH python3 << 'PYEOF'
import csv, os, collections, datetime, subprocess, json
from concurrent.futures import ThreadPoolExecutor

colo_csv = os.environ["COLOS"]
top_n = int(os.environ["TOP_N"])
label = os.environ["LABEL"]
port = os.environ["PORT"]
out_dir = os.environ["OUT_DIR"]
abuse_key = os.environ.get("ABUSEIPDB_KEY", "")
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

def curl_json(url, headers=None, timeout=12):
    cmd = ["curl", "-s", "--max-time", str(timeout)]
    for k, v in (headers or {}).items():
        cmd += ["-H", f"{k}: {v}"]
    cmd.append(url)
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 3)
    return json.loads(r.stdout or "{}")

def dl_mbps(ip):
    try:
        r = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{speed_download}",
             "--max-time", "8", "--resolve", f"speed.cloudflare.com:{port}:{ip}", DL_URL],
            capture_output=True, text=True, timeout=13)
        return float(r.stdout or 0) * 8 / 1_000_000
    except Exception:
        return 0.0

def free_check(ip):
    """免费方案: proxycheck(机房类型) + ipinfo(anycast=广播) + AbuseIPDB(风控分)"""
    res = {"risk": None, "idc": None, "native": None, "source": "free"}
    # 1. proxycheck.io — 机房/ISP 类型判断（免费 1000次/天，key=free）
    try:
        d = curl_json(f"https://proxycheck.io/v2/{ip}?key=free&vpn=1", timeout=10)
        info = d.get(ip, {}) if isinstance(d, dict) else {}
        if isinstance(info, dict) and "type" in info:
            res["idc"] = str(info["type"]).lower() in ("business", "hosting", "education")
    except Exception:
        pass
    # 2. ipinfo.io — anycast=True 即广播 IP（非原生）
    try:
        d = curl_json(f"https://ipinfo.io/{ip}/json", timeout=10)
        if "anycast" in d:
            res["native"] = not bool(d["anycast"])
    except Exception:
        pass
    # 3. AbuseIPDB — 滥用置信度评分（免费注册 key，每天1000次）
    if abuse_key:
        try:
            d = curl_json(f"https://api.abuseipdb.com/api/v2/check?ipAddress={ip}&maxAgeInDays=90",
                          headers={"Key": abuse_key, "Accept": "application/json"}, timeout=12)
            data = d.get("data", {}) if isinstance(d, dict) else {}
            if "abuseConfidenceScore" in data:
                res["risk"] = int(data["abuseConfidenceScore"])
        except Exception:
            pass
    return res

def purity_check(ip):
    return free_check(ip)

def fmt_purity(p):
    """标注: 风控26% 机房IP 广播IP（字段缺失时省略）"""
    if not p:
        return ""
    parts = []
    if p.get("risk") is not None:
        parts.append(f"风控{p['risk']}%")
    if p.get("idc") is True:
        parts.append("机房IP")
    elif p.get("idc") is False:
        parts.append("非机房IP")
    if p.get("native") is True:
        parts.append("原生IP")
    elif p.get("native") is False:
        parts.append("广播IP")
    return (" " + " ".join(parts)) if parts else ""

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
    purities = {ip: p for ip, p in zip([j[1] for j in jobs], ex.map(purity_check, [j[1] for j in jobs]))}
for colo in picks:
    picks[colo] = [(lat, ip, speeds[ip], purities[ip]) for lat, ip, _, _ in picks[colo]]

date_str = datetime.date.today().strftime("%Y-%m-%d")
lines = [f"Cloudflare 优选 IP（{date_str}）", "=" * 60]
mode = "免费(AbuseIPDB+proxycheck+ipinfo)" if abuse_key else "免费(proxycheck+ipinfo，未配AbuseIPDB无风控分)"

for colo in requested:
    name = REGION_NAMES.get(colo, colo)
    if colo not in picks:
        lines.append(f"# {colo}（{name}）: 本轮未测到可用 IP")
        continue
    # 按风控值过滤（仅当拿到风控分）
    kept, filtered = [], []
    for lat, ip, mbps, p in picks[colo]:
        if p and p.get("risk") is not None and p["risk"] > risk_max:
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
print(f"\n✅ 已更新: {out_dir}（纯净度模式: {mode}，风控>{risk_max}% 自动过滤）")
print("   备注标签: " + label + "（可改脚本第 3 个参数）")
PYEOF
echo "==> [3/4] 完成"
