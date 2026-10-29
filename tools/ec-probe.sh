#!/usr/bin/env bash
# ec-probe.sh — EC RAM 状态探针（Lecoo N155A / BIOS 2.5）
#
# 目的：判断"睡眠/唤醒"是否在 EC 内部留下持久状态。
# EC RAM 里大量字节是持续刷新的计数器，直接 diff 没有意义；
# 本工具按"同一状态内多次采样 + 位级稳定性"筛出真正的状态位。
#
# 用法（fish 里直接跑，不需要切到 bash）：
#   ./tools/ec-probe.sh setup      # 加载 ec_sys（只读），定位接口
#   ./tools/ec-probe.sh clean      # 采干净基线（开机静置 2 分钟后再执行）
#   ./tools/ec-probe.sh sleep      # 进入睡眠；醒来后选择 a(自动)/m(手动)，自动采样
#   ./tools/ec-probe.sh report     # 基线 vs 所有其它记录
#   ./tools/ec-probe.sh list       # 列出已采集的状态
#   ./tools/ec-probe.sh compare A B
#
# 环境变量：
#   SAMPLES=5        每次采样次数
#   INTERVAL=5       采样间隔（秒）
#   DATA_DIR=<path>  数据目录（默认 ./ec-data）
#
# 设计约束：
#   * 只读：绝不写 EC，也不会加载 write_support=1。
#   * 不改系统配置，数据只写 DATA_DIR。
#   * 目录名带时间戳，重复实验不会互相覆盖。
#   * 所有涉及 /sys/kernel/debug 的探测都通过 sudo 执行 —— 该目录是 0700 root，
#     普通用户的 test/glob 会直接失败，不能用它判断接口是否存在。

set -euo pipefail

DATA_DIR="${DATA_DIR:-$PWD/ec-data}"
SAMPLES="${SAMPLES:-5}"
INTERVAL="${INTERVAL:-5}"
EC_IO="${EC_IO:-}"
SUDO=""
[[ ${EUID} -ne 0 ]] && SUDO="sudo"

log()  { printf '[ec-probe] %s\n' "$*"; }
warn() { printf '[ec-probe] ! %s\n' "$*" >&2; }
die()  { printf '[ec-probe] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法: ./tools/ec-probe.sh <命令>

  setup            加载 ec_sys（只读）并定位 /sys/kernel/debug/ec/ecN/io
  clean            采一份干净基线（建议开机静置 2 分钟后再执行）
  sleep            进入 s2idle；唤醒后按提示选 a(自动)/m(手动)，随即采样
  report           用最新的 clean-* 与其它所有记录做对比
  list             列出已采集的状态
  compare A B      指定两份记录做对比（可写目录名或绝对路径）
  restore BASE OFF [OFF...]
                   把指定偏移恢复为基线值（**会写 EC**，需二次确认）
                   例: restore clean-1029-1730 0xA7 0xB1
  wake             记录 GPE/GPIO 计数 → 睡一次 → 再记录 → 打印唤醒源增量

环境变量: SAMPLES=5 INTERVAL=5 DATA_DIR=./ec-data RESTORE_YES=1(跳过确认)
EOF
}

# ---------------------------------------------------------------- EC 接口
# 注意：/sys/kernel/debug 是 0700 root，普通用户连目录都进不去，
# 因此 existence/glob 必须放在 sudo 下执行。
detect_ec() {
    local p
    p=$($SUDO sh -c 'ls -1d /sys/kernel/debug/ec/ec*/io 2>/dev/null | head -1') || true
    [[ -n "$p" ]] || return 1
    EC_IO="$p"
    return 0
}

require_ec() {
    if [[ -n "$EC_IO" ]] && $SUDO test -r "$EC_IO" 2>/dev/null; then
        return 0
    fi
    if detect_ec && $SUDO test -r "$EC_IO" 2>/dev/null; then
        return 0
    fi
    die "找不到可读的 EC 接口。先执行 ./tools/ec-probe.sh setup 看诊断信息。"
}

# 非致命版本：返回 1 而不是 exit。
# 用于 wake 这类"EC 只是附加信息"的路径——旧版在这里用 require_ec，
# 一旦 ec_sys 没加载（重启后不会自动加载），die 的 exit 会让整个脚本
# 静默退出（stderr 又被 2>/dev/null 吞掉），表现为"命令执行不了也没报错"。
have_ec() {
    if [[ -n "$EC_IO" ]] && $SUDO test -r "$EC_IO" 2>/dev/null; then
        return 0
    fi
    detect_ec >/dev/null 2>&1 || return 1
    $SUDO test -r "$EC_IO" 2>/dev/null
}

cmd_setup() {
    # 1) debugfs
    if ! grep -q "on /sys/kernel/debug type debugfs" /proc/mounts; then
        log "debugfs 未挂载，尝试挂载..."
        $SUDO mount -t debugfs none /sys/kernel/debug || die "debugfs 挂载失败"
    fi

    # 2) 模块：失败时把 modprobe 的真实报错显示出来（旧版把它吞了）
    if grep -q "^ec_sys " /proc/modules; then
        log "ec_sys 已加载"
    else
        local out
        if ! out=$($SUDO modprobe ec_sys 2>&1); then
            die "modprobe ec_sys 失败：${out:-无输出}
      可能原因：内核未启用 CONFIG_ACPI_EC_DEBUGFS，或 Secure Boot 拒绝未签名模块。
      确认: zgrep ACPI_EC_DEBUGFS /proc/config.gz ; dmesg | tail"
        fi
        log "ec_sys 已加载"
    fi

    # 3) 接口枚举（sudo 下）
    detect_ec || die "ec_sys 已加载，但没有 /sys/kernel/debug/ec/ec*/io
      排查: lsmod | grep ec_sys ; dmesg | grep -i 'ACPI: EC' ; ls /sys/class/ec"
    $SUDO test -r "$EC_IO" || die "接口存在但当前用户不可读：$EC_IO"

    # 4) 试读一个字节，确认真的能读
    $SUDO dd if="$EC_IO" of=/dev/null bs=1 count=1 status=none 2>/dev/null \
        || die "试读失败：$EC_IO（EC 忙或接口异常）"

    # 5) 预热 sudo，避免采样过程中重新要密码
    $SUDO -v 2>/dev/null || true
    mkdir -p "$DATA_DIR"

    log "接口就绪：$EC_IO（只读）"
    log "write_support = $(cat /sys/module/ec_sys/parameters/write_support 2>/dev/null || echo '?')（应为 0）"
    log "数据目录：$DATA_DIR"
    log "下一步：静置 2 分钟后执行  ./tools/ec-probe.sh clean"
}

# ---------------------------------------------------------------- 采样
capture() {  # $1 = 标签
    local label="$1" dir="$DATA_DIR/$1" i uniq
    require_ec
    mkdir -p "$dir"; rm -f "$dir"/*.bin
    log "采样 $SAMPLES 次，间隔 ${INTERVAL}s → $dir"
    for ((i = 1; i <= SAMPLES; i++)); do
        $SUDO dd if="$EC_IO" of="$dir/s$i.bin" bs=1 count=256 status=none 2>/dev/null \
            || die "读取 EC RAM 失败：$EC_IO"
        if (( i < SAMPLES )); then sleep "$INTERVAL"; fi
    done
    uniq=$(md5sum "$dir"/*.bin | awk '{print $1}' | sort -u | wc -l)
    log "完成（$uniq 个不同指纹；>1 表示采样期间有字节在刷新，分析时按位过滤）"
}

cmd_clean() {
    require_ec
    capture "clean-$(date +%m%d-%H%M%S)"
    log "下一步：./tools/ec-probe.sh sleep"
}

cmd_sleep() {
    require_ec
    log "即将进入 s2idle。醒来后请如实选择唤醒方式（自动醒 / 你按键唤醒）。"
    sleep 1
    systemctl suspend || die "systemctl suspend 失败"
    sleep 2
    local last
    last=$(journalctl -b -k -o cat --no-pager 2>/dev/null | grep -a "Timekeeping suspended" | tail -1 || true)
    log "本次记录：${last:-（未找到 Timekeeping 行）}"
    printf '[ec-probe] 这次是自动醒(a) 还是你按键唤醒(m)？[a/m] '
    local ans=""
    read -r ans || true
    case "${ans:-a}" in
        m | M) capture "manual-$(date +%m%d-%H%M%S)" ;;
        *)     capture "auto-$(date +%m%d-%H%M%S)" ;;
    esac
    log "下一步：./tools/ec-probe.sh report"
}

cmd_list() {
    [[ -d "$DATA_DIR" ]] || { log "还没有数据（$DATA_DIR 不存在）"; return 0; }
    local d
    for d in "$DATA_DIR"/*/; do
        [[ -d "$d" ]] || continue
        printf '  %-28s %s 个样本\n' "$(basename "$d")" "$(find "$d" -name '*.bin' | wc -l)"
    done
}

# ---------------------------------------------------------------- 分析
analyze() {  # $1 $2 = 目录
    python3 - "$1" "$2" <<'PY'
import os, sys, glob

MAP = {0x07:'SHIP',0x0C:'ECBY',0x20:'RCMD',0x21:'RCST',0x22:'TESR',0x30:'XXTT',0x32:'TLID',
       0x33:'TLIE',0x38:'RTSC',0x40:'SSD1',0x4B:'FNS1',0x4F:'FNS2',0x62:'TSR4',0x63:'TSI/HYST',
       0x64:'TSHT',0x65:'TSLT',0x66:'TSSR',0x68:'BATE',0x6A:'TBAT',0x70:'TSRC',0x72:'TSR1',
       0x73:'TSR3',0x74:'TS4H',0x75:'TS4L',0x7C:'PWMD',0x7D:'DGTP',0x7E:'RESV/GPUS/BTSB/NTTE',
       0x7F:'LSTE',0x80:'ECWR',0x84:'B1DC',0x86:'B1FV',0x88:'B1FC',0x8C:'B1ST',0x8D:'B1CR',
       0x8F:'B1RC',0x91:'B1VT',0x93:'BPCN',0x95:'BACC',0xA7:'WOLE/BYCF/ECS3/B1PN',
       0xA9:'AIPO/LOPO',0xAF:'VBUS',0xB0:'CCDP',0xB1:'PPMD',0xB4:'PDAH',0xB5:'PDAL',
       0xBE:'PDMX',0xBF:'PDMN',0xEA:'PDIN',0xF0:'TPCC/DRMD',0xF5:'ATPU'}
BITS = {(0xA7,0):'WOLE',(0xA7,1):'BYCF',(0xA7,4):'ECS3',(0xA7,6):'B1PN',
        (0xA9,0):'AIPO',(0xA9,1):'LOPO',(0x7E,4):'GPUS',(0x7E,5):'BTSB',(0x7E,7):'NTTE',
        (0x40,4):'SSD2',(0x63,4):'HYST',(0xEA,4):'PDIN',(0xF0,3):'TPCC',(0xF0,6):'DRMD'}

def load(d):
    files = sorted(glob.glob(os.path.join(d, '*.bin')))
    if not files:
        sys.exit(f'[ec-probe] {d} 里没有 *.bin')
    return [open(f, 'rb').read() for f in files]

A, B = load(sys.argv[1]), load(sys.argv[2])
n = min(min(map(len, A)), min(map(len, B)))
print(f'  A = {os.path.basename(sys.argv[1].rstrip("/"))}  ({len(A)} 样本)')
print(f'  B = {os.path.basename(sys.argv[2].rstrip("/"))}  ({len(B)} 样本)')
hi, lo = [], []
for i in range(n):
    va = {x[i] for x in A}
    vb = {x[i] for x in B}
    if len(va) == 1 and len(vb) == 1:
        a, b = va.pop(), vb.pop()
        if a != b:
            hi.append(f'  0x{i:02X}        {a:02X} -> {b:02X}   (xor {a ^ b:08b})   [{MAP.get(i, "?")}]')
    else:
        ra, rb = (min(va), max(va)), (min(vb), max(vb))
        narrow = (ra[1] - ra[0] < 16) and (rb[1] - rb[0] < 16)
        for bit in range(8):
            ba = {(x[i] >> bit) & 1 for x in A}
            bb = {(x[i] >> bit) & 1 for x in B}
            if len(ba) == 1 and len(bb) == 1 and ba != bb:
                tag = BITS.get((i, bit), MAP.get(i, '?'))
                note = f'  (范围 A={ra[0]}-{ra[1]} B={rb[0]}-{rb[1]})'
                if narrow:
                    note += '  ← 窄范围计数器，可能是巧合'
                lo.append(f'  0x{i:02X}.bit{bit}   {ba.pop()} -> {bb.pop()}   [{tag}]{note}')
print('  -- 字节级（高置信：整个字节在两种状态下各自稳定且不同） --')
for l in hi:
    print(l)
if not hi:
    print('   （无）')
print('  -- 位级（该字节本身在刷新，仅某一位稳定：需结合语义判断） --')
for l in lo:
    print(l)
if not lo:
    print('   （无）')
print(f'  ---- 字节级 {len(hi)} 项 / 位级 {len(lo)} 项 ----')
if not hi and not lo:
    print('  （无差异：该状态没有留下可读的持久标志）')
PY
}

cmd_compare() {
    local a="$1" b="$2"
    [[ -d "$a" ]] || a="$DATA_DIR/$a"
    [[ -d "$b" ]] || b="$DATA_DIR/$b"
    [[ -d "$a" ]] || die "找不到目录：$a"
    [[ -d "$b" ]] || die "找不到目录：$b"
    analyze "$a" "$b"
}

# 唤醒源快照：GPE 计数/标志 + ACPI GPIO 事件计数 + 上次唤醒 IRQ
wake_snapshot() {  # $1 = 输出文件
    {
        for f in /sys/firmware/acpi/interrupts/gpe[0-9A-Fa-f][0-9A-Fa-f]; do
            [[ -r "$f" ]] || continue
            read -r n flags rest < <(cat "$f" 2>/dev/null) || continue
            [[ "${n:-0}" == "0" ]] && continue
            echo "GPE $(basename "$f") $n ${flags:-} ${rest:-}"
        done
        python3 - <<'PY'
for l in open('/proc/interrupts'):
    p = l.split()
    if len(p) > 4 and p[-1] == 'ACPI:Event':
        print('GPIO', p[-2], sum(int(x) for x in p[1:-3] if x.isdigit()))
PY
        echo "IRQ last $(cat /sys/power/pm_wakeup_irq 2>/dev/null || echo none)"
    } > "$1"
}

cmd_wake() {
    if ! have_ec; then
        warn "EC 接口不可读（ec_sys 未加载？先 sudo modprobe ec_sys）——wake 继续，仅缺少 EC 快照"
    fi
    mkdir -p "$DATA_DIR/../.tmp" 2>/dev/null || true
    local a=/tmp/ec-wake-before.$$ b=/tmp/ec-wake-after.$$
    wake_snapshot "$a"
    log "已记录基线计数，现在进入 s2idle（会阻塞到系统醒来）..."
    systemctl suspend || die "systemctl suspend 失败"
    sleep 2
    wake_snapshot "$b"
    log "本次记录：$(journalctl -b -k -o cat --no-pager 2>/dev/null | grep -a 'Timekeeping suspended' | tail -1 || echo '无')"
    python3 - "$a" "$b" <<'PY'
import sys

def load(p):
    d = {}
    last = 'none'
    for l in open(p):
        f = l.split()
        if not f:
            continue
        if f[0] == 'IRQ':
            last = f[-1]
            continue
        d[(f[0], f[1])] = (int(f[2]), ' '.join(f[3:]))
    return d, last

A, _ = load(sys.argv[1])
B, last = load(sys.argv[2])
print('  -- 计数增量 --')
hit = 0
for k in sorted(set(A) | set(B)):
    a = A.get(k, (0, ''))
    b = B.get(k, (0, ''))
    if b[0] != a[0]:
        hit += 1
        flags = b[1] if b[1] != a[1] else a[1]
        note = f'  [{flags}]' if flags else ''
        print(f'  {k[0]:4} {k[1]:8} {a[0]:>6} -> {b[0]:<6} (+{b[0]-a[0]}){note}')
if not hit:
    print('   （无增量：这次没等到事件就醒了，或计数未变）')
print(f'  -- pm_wakeup_irq = {last} --')
PY
    rm -f "$a" "$b"
}

cmd_restore() {  # $1 = 基线目录, 其余为偏移
    local base="$1"; shift
    [[ -d "$base" ]] || base="$DATA_DIR/$base"
    [[ -f "$base/s1.bin" ]] || die "找不到基线样本：$base/s1.bin"
    (( $# )) || die "用法: restore <baseline> <offset> [offset...]  例: restore clean-... 0xA7"
    local off
    for off in "$@"; do
        [[ "$off" =~ ^(0x)?[0-9A-Fa-f]{1,2}$ ]] || die "偏移不合法：$off"
    done

    if [[ "${RESTORE_YES:-0}" != "1" ]]; then
        printf '[ec-probe] 即将把以下偏移写回基线值（写 EC RAM）: %s\n' "$*"
        printf '[ec-probe] 基线与目标：%s → %s\n' "$base/s1.bin" "${EC_IO:-自动检测}"
        printf '[ec-probe] 继续请输入 yes：'
        local a=""; read -r a || true
        [[ "$a" == "yes" || "$a" == "y" ]] || die "已取消"
    fi

    log "切换到写模式（重新加载 ec_sys write_support=1）"
    $SUDO modprobe -r ec_sys 2>/dev/null || warn "卸载 ec_sys 失败（可能仍被占用）"
    $SUDO modprobe ec_sys write_support=1 || die "加载 ec_sys write_support=1 失败"
    detect_ec || die "写模式下找不到 EC 接口"
    $SUDO test -w "$EC_IO" || die "接口不可写：$EC_IO"

    local before after
    for off in "$@"; do
        off=$((off))
        before=$($SUDO dd if="$EC_IO" bs=1 skip="$off" count=1 status=none 2>/dev/null | od -An -tu1 | tr -d ' ')
        $SUDO dd if="$base/s1.bin" of="$EC_IO" bs=1 skip="$off" seek="$off" count=1 conv=notrunc status=none 2>/dev/null \
            || die "写入失败 offset=0x$(printf '%02X' "$off")"
        after=$($SUDO dd if="$EC_IO" bs=1 skip="$off" count=1 status=none 2>/dev/null | od -An -tu1 | tr -d ' ')
        printf '[ec-probe] 0x%02X: %s -> %s\n' "$off" "${before:-?}" "${after:-?}"
    done

    log "恢复只读模式"
    $SUDO modprobe -r ec_sys 2>/dev/null || warn "卸载失败"
    $SUDO modprobe ec_sys 2>/dev/null || warn "重新加载 ec_sys 失败"
    log "完成。随后直接关机测试因果：systemctl poweroff"
}

cmd_report() {
    [[ -d "$DATA_DIR" ]] || die "还没有数据"
    local base
    base=$(ls -1dt "$DATA_DIR"/clean-*/ 2>/dev/null | head -1)
    [[ -n "$base" ]] || die "还没有基线，先执行 clean"
    log "基线：$(basename "${base%/}")"
    local d
    for d in "$DATA_DIR"/*/; do
        [[ -d "$d" ]] || continue
        [[ "${d%/}" == "${base%/}" ]] && continue
        printf '\n[ec-probe] ===== %s vs %s =====\n' "$(basename "${base%/}")" "$(basename "${d%/}")"
        analyze "$base" "$d" || true
    done
}

case "${1:-help}" in
    setup)   cmd_setup ;;
    clean)   cmd_clean ;;
    sleep)   cmd_sleep ;;
    report)  cmd_report ;;
    list)    cmd_list ;;
    compare) shift; [[ $# -ge 2 ]] || die "用法: compare <dirA> <dirB>"; cmd_compare "$1" "$2" ;;
    restore) shift; [[ $# -ge 2 ]] || die "用法: restore <baseline> <offset> [offset...]"; cmd_restore "$@" ;;
    wake)    cmd_wake ;;
    help | -h | --help) usage ;;
    *) echo "未知命令：$1" >&2; usage; exit 2 ;;
esac
