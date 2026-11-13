#!/bin/bash
# Lyrune macOS 性能采集脚本（无 sudo 也能工作）
#
# 用途：在没有 Instruments CLI 的机器上采集 Lyrune 的进程级与整机 GPU 指标，
# 并与另一份采集结果做结构化对比。改动背景、确定性指标与已知限制见
# docs/macos-performance.md。
#
# 用法：
#   measure-macos-perf.sh --label <名称> --out <目录> [选项]
#   measure-macos-perf.sh --compare <基线目录> <候选目录>
#
# 采集选项：
#   --app <path>        .app 包或可执行文件；给了就由脚本启动并在结束时结束它
#   --pid <pid>         直接采集一个已经在跑的 Lyrune 进程（不在结束时结束它）
#   --duration <秒>     采样时长，默认 20
#   --settle <秒>       启动后静置时长，默认 8
#   --playback          播放场景：先提示用户登录、播放并展开歌词页，回车后开始采样
#   --sample            额外抓 3 秒 sample 栈（/usr/bin/sample，无需 sudo）
#   --gpu               每秒同时记录 ioreg 的 GPU 利用率（整机口径，含 WindowServer）
#   --out <dir>         输出目录（默认 ./perf-out）
#
# 输出（全部无 sudo）：
#   <out>/<label>/metrics.tsv   指标表（metric<TAB>value<TAB>unit<TAB>method）
#   <out>/<label>/ps.csv        原始 ps 采样    <out>/<label>/top.txt  top 快照
#   <out>/<label>/sample.txt    可选栈采样      <out>/<label>/meta.txt 环境与方法
#
# 说明：
#   - 进程唤醒次数（wakeups）在 macOS 上只能通过需要 sudo 的 powermetrics 获取；
#     本脚本在没有 sudo 时自动降级为"累计 CPU 时间差分 + top 瞬时 CPU"，并在
#     metrics.tsv 里明确标注 wakeups=N/A。sudo 可用时会顺带采集 CPU 频率/空闲占比。
#   - 真实播放场景必须先人工登录（Lyrune 无凭据时只显示扫码登录页），
#     所以 --playback 是交互式的：脚本提示、用户操作、回车后才开始计时。
#
set -u

OUT_BASE="./perf-out"
LABEL=""
APP=""
PID=""
DURATION=20
SETTLE=8
PLAYBACK=0
DO_SAMPLE=0
DO_GPU=0
COMPARE=0
A_DIR=""
B_DIR=""

die() { echo "错误: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1"; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --label) LABEL=${2:?}; shift 2 ;;
    --app) APP=${2:?}; shift 2 ;;
    --pid) PID=${2:?}; shift 2 ;;
    --duration) DURATION=${2:?}; shift 2 ;;
    --settle) SETTLE=${2:?}; shift 2 ;;
    --playback) PLAYBACK=1; shift ;;
    --sample) DO_SAMPLE=1; shift ;;
    --gpu) DO_GPU=1; shift ;;
    --out) OUT_BASE=${2:?}; shift 2 ;;
    --compare) COMPARE=1; A_DIR=${2:?}; B_DIR=${3:?}; shift 3 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数 $1（--help 查看用法）" ;;
  esac
done

need ps
need top

loadavg() { sysctl -n vm.loadavg | tr -d '{}' | awk '{printf "%s,%s,%s", $1, $2, $3}'; }

# 累计 CPU 时间（user+sys，秒）
cpu_seconds() { ps -p "$1" -o time= | awk -F: '{ if (NF==3) print $1*3600+$2*60+$3; else print $1*60+$2 }'; }

rss_kb() { ps -p "$1" -o rss= | awk '{print $1}'; }

threads() {
  # ps -M 列出每个线程一行，最可靠；top 的 #TH 作为补充
  local n
  n=$(ps -M -p "$1" 2>/dev/null | awk 'NR>1 {n++} END {print n+0}')
  if [ "${n:-0}" = "0" ]; then
    n=$(top -l 1 -pid "$1" -stats threads 2>/dev/null | awk -v pid="$1" 'NR>1 && $1==pid {print $2}' | tail -1)
  fi
  echo "${n:-N/A}"
}

median_of() { sort -n | awk '{a[NR]=$1} END { if (NR==0) {print "N/A"; exit} if (NR%2) print a[(NR+1)/2]; else printf "%.1f", (a[NR/2]+a[NR/2+1])/2 }'; }
max_of() { sort -n | tail -1; }

# 真实播放场景的交互提示
if [ "$PLAYBACK" = 1 ]; then
  cat <<'EOF'
================================================================
播放场景采集（需要人工完成，因为 Lyrune 未登录时无法真实播放）：
  1. 如果还没有登录：在 App 里扫码登录 QQ 音乐；
  2. 播放任意一首歌，暂停/播放都行，建议保持播放；
  3. 打开歌词页并展开（点击封面/向下箭头进入全屏歌词）；
  4. 让窗口保持可见、不要最小化，切换到本终端；
  5. 准备好后按回车开始计时采样。
================================================================
EOF
  read -r _
fi

if [ "$COMPARE" = 1 ]; then
  a_metrics="$A_DIR/metrics.tsv"; b_metrics="$B_DIR/metrics.tsv"
  [ -f "$a_metrics" ] || die "找不到 $a_metrics"
  [ -f "$b_metrics" ] || die "找不到 $b_metrics"
  echo ""
  echo "| 指标 | 基线 | 候选 | 变化 |"
  echo "| --- | --- | --- | --- |"
  # 按基线顺序输出；数值型给倍数，N/A 给 —
  python3 - "$a_metrics" "$b_metrics" <<'PY'
import sys
def load(p):
    d = {}
    order = []
    for line in open(p):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        k, v = parts[0], parts[1]
        d[k] = v
        order.append(k)
    return d, order
a, order = load(sys.argv[1])
b, _ = load(sys.argv[2])
def num(x):
    try: return float(x)
    except Exception: return None
for k in order:
    if k in ("label", "loadavg_before", "loadavg_after"):
        continue
    av, bv = a.get(k, "N/A"), b.get(k, "N/A")
    na, nb = num(av), num(bv)
    if na is not None and nb is not None and na != 0:
        ratio = nb / na
        change = f"{ratio:.3f}x"
        if ratio < 1:
            change += f"（-{(1-ratio)*100:.1f}%）"
        else:
            change += f"（+{(ratio-1)*100:.1f}%）"
    else:
        change = "—"
    print(f"| {k} | {av} | {bv} | {change} |")
PY
  exit 0
fi

[ -n "$LABEL" ] || die "缺少 --label"
if [ -z "$PID" ]; then
  [ -n "$APP" ] || die "需要 --app 或 --pid"
  case "$APP" in
    *.app) BIN="$APP/Contents/MacOS/$(basename "$APP" .app)"; [ -x "$BIN" ] || BIN=$(find "$APP/Contents/MacOS" -maxdepth 1 -type f -perm -111 | head -1) ;;
    *) BIN="$APP" ;;
  esac
  [ -x "$BIN" ] || die "不可执行: $BIN"
  "$BIN" >/dev/null 2>&1 &
  PID=$!
  LAUNCHED=1
  sleep "$SETTLE"
  kill -0 "$PID" 2>/dev/null || die "进程启动后立即退出: $BIN"
else
  LAUNCHED=0
  kill -0 "$PID" 2>/dev/null || die "pid $PID 不存在"
fi

OUT="$OUT_BASE/$LABEL"
mkdir -p "$OUT"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
{
  echo "label=$LABEL"
  echo "pid=$PID"
  echo "binary=${BIN:-attached}"
  echo "started_utc=$NOW"
  echo "duration_s=$DURATION"
  echo "playback=$PLAYBACK"
  echo "os=$(sw_vers -productVersion) arch=$(uname -m) model=$(sysctl -n hw.model)"
  echo "cpus=$(sysctl -n hw.ncpu) mem_bytes=$(sysctl -n hw.memsize)"
  echo "loadavg_before=$(loadavg)"
  echo "method=cpu: ps -o time 累计 CPU 差分 / 墙钟; rss: ps -o rss; threads: top #TH; 无 sudo 时 wakeups 不可测"
} >"$OUT/meta.txt"

THREADS0=$(threads "$PID")
CPU0=$(cpu_seconds "$PID")
T0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')

if [ "$DO_GPU" = 1 ]; then
  echo "t_epoch,cpu_time_s,dev_util_pct,renderer_util_pct,tiler_util_pct" >"$OUT/gpu.csv"
fi
gpu_util() { ioreg -r -c IOAccelerator -d 1 2>/dev/null | grep -o "\"$1\"=[0-9]*" | head -1 | cut -d= -f2; }
echo "t_epoch,cpu_time_s,rss_kb" >"$OUT/ps.csv"
RSS_LIST=$(mktemp)
CPU_LAST="$CPU0"
T_LAST="$T0"
for _ in $(seq 1 "$DURATION"); do
  sleep 1
  T=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  C=$(cpu_seconds "$PID" 2>/dev/null) || break
  R=$(rss_kb "$PID" 2>/dev/null) || break
  echo "$T,$C,$R" >>"$OUT/ps.csv"
  if [ "$DO_GPU" = 1 ]; then
    echo "$T,$C,$(gpu_util 'Device Utilization %'),$(gpu_util 'Renderer Utilization %'),$(gpu_util 'Tiler Utilization %')" >>"$OUT/gpu.csv"
  fi
  echo "$R" >>"$RSS_LIST"
  CPU_LAST="$C"; T_LAST="$T"
done

top -l 2 -pid "$PID" -s 1 -stats pid,cpu,mem,rsize,threads,power,state >"$OUT/top.txt" 2>&1 || true
if [ "$DO_SAMPLE" = 1 ] && [ -x /usr/bin/sample ]; then
  /usr/bin/sample "$PID" 3 -file "$OUT/sample.txt" >/dev/null 2>&1 || true
fi

CPU_DELTA=$(perl -e 'printf "%.2f", $ARGV[1]-$ARGV[0]' "$CPU0" "$CPU_LAST")
WALL=$(perl -e 'printf "%.2f", $ARGV[1]-$ARGV[0]' "$T0" "$T_LAST")
AVG_CPU=$(perl -e 'printf "%.2f", ($ARGV[1]>0 ? $ARGV[0]/$ARGV[1]*100 : 0)' "$CPU_DELTA" "$WALL")
TOP_CPU=$(awk '/^'"$PID"' / {v=$2} END {print v}' "$OUT/top.txt")
TOP_CPU=${TOP_CPU:-N/A}
RSS_MEDIAN=$(median_of <"$RSS_LIST")
RSS_MAX=$(max_of <"$RSS_LIST")
THREADS1=$(threads "$PID")
LOAD_AFTER=$(loadavg)

# 可选：sudo 可用时采集整机 CPU 频率/idle 作为补充
WAKEUPS="N/A"
if command -v powermetrics >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  sudo -n powermetrics -n 2 -i 500 --samplers cpu_power 2>/dev/null \
    | awk '/CPU Power|PCPU/{print}' >"$OUT/powermetrics.txt" || true
  WAKEUPS="见 powermetrics.txt"
fi

{
  echo -e "# metric\tvalue\tunit\tmethod"
  echo -e "avg_cpu_pct\t$AVG_CPU\t%\t累计 CPU 差分/墙钟（$DURATION s）"
  echo -e "top_cpu_pct\t$TOP_CPU\t%\ttop -l 2 第二帧瞬时值"
  echo -e "rss_median_mb\t$(perl -e 'printf "%.1f", $ARGV[0]/1024' "$RSS_MEDIAN")\tMB\tps -o rss 中位数"
  echo -e "rss_max_mb\t$(perl -e 'printf "%.1f", $ARGV[0]/1024' "$RSS_MAX")\tMB\tps -o rss 最大值"
  echo -e "threads_start\t${THREADS0:-N/A}\t个\ttop #TH"
  echo -e "threads_end\t${THREADS1:-N/A}\t个\ttop #TH"
  echo -e "wakeups_per_s\t$WAKEUPS\t次/秒\t需要 sudo powermetrics；无 sudo 时不可测"
  echo -e "cpu_time_delta\t$CPU_DELTA\ts\tps -o time 差分"
  if [ "$DO_GPU" = 1 ]; then
    python3 - "$OUT/gpu.csv" >>"$OUT/metrics.tsv" <<'PYEOF'
import sys, statistics
rows = []
for line in open(sys.argv[1]).read().strip().splitlines()[1:]:
    p = line.split(",")
    if len(p) >= 3 and p[2]:
        rows.append(float(p[2]))
if rows:
    rows.sort()
    print(f"gpu_dev_util_mean\t{statistics.mean(rows):.1f}\t%\tioreg IOAccelerator Device Utilization %（整机 GPU，非单进程）")
    print(f"gpu_dev_util_median\t{statistics.median(rows):.1f}\t%\t同上")
    print(f"gpu_dev_util_p90\t{rows[min(len(rows)-1, len(rows)*9//10)]:.1f}\t%\t同上")
PYEOF
  fi
  echo -e "loadavg_before\t$(sed -n 's/^loadavg_before=//p' "$OUT/meta.txt")\t-\t采样开始前 1/5/15 分钟负载"
  echo -e "loadavg_after\t$LOAD_AFTER\t-\t采样结束后负载"
} >"$OUT/metrics.tsv"

{
  echo "label=$LABEL"
  echo "loadavg_before=$(sed -n 's/^loadavg_before=//p' "$OUT/meta.txt")"
  echo "loadavg_after=$LOAD_AFTER"
  echo "finished_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
} >>"$OUT/meta.txt"

if [ "$LAUNCHED" = 1 ]; then kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; fi
rm -f "$RSS_LIST"

echo ""
echo "采集完成: $OUT"
awk -F'\t' '!/^#/ {printf "  %-16s %s %s\n", $1, $2, $3}' "$OUT/metrics.tsv"
echo ""
echo "对比: $0 --compare <基线目录> <候选目录>"
