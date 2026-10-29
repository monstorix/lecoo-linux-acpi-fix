#!/usr/bin/env bash
# lecoo-nic-unbind — 关机前解绑有线网卡驱动，消除 S5 偶发重启
#
# 依据（2026-10-29 实测，BIOS 2.5 / N155A / CachyOS）：
#   * 纯原厂表 + 4 个内核参数：关机偶发 1–2 秒后自动上电；
#   * 表内 _AEI 0x0018 改非唤醒后，s2idle 瞬醒根治（20 s / 1375 s / 8.9 s
#     三次全部手动唤醒，GPIO 24 零增量），但关机重启仍零星出现；
#   * 手动 `echo 0000:0c:00.0 > /sys/bus/pci/drivers/r8169/unbind` 之后
#     连续 6 次关机全部干净——期间还包含 3 次"瞬醒后关机"。
#   → 触发点在 r8169 驱动的关机路径（D3 / WOL / WAKE# 线），与 ACPI 的
#     唤醒声明无关（后者已被表和 wake-guard 处理掉），因此只能在关机前
#     把驱动摘掉。
#
# 用法（apply / bind 需要 root；非 root 会自动用 sudo 重入）：
#   lecoo-nic-unbind.sh apply     解绑（默认；关机时由 ExecStop 调用）
#   lecoo-nic-unbind.sh bind      重新绑定（手工回退用）
#   lecoo-nic-unbind.sh status    只打印当前状态，不修改（普通用户可用）
#
# 约束：
#   * 只做"当前已绑定则解绑"，幂等；
#   * 失败不阻断关机（unit 侧另有 TimeoutStopSec 兜底）；
#   * 仅影响本次开机，重启后由内核重新枚举、驱动自动绑定。

set -uo pipefail

DRIVER="${DRIVER:-r8169}"
SYS="/sys/bus/pci/drivers/$DRIVER"

log() {
    printf '[lecoo-nic-unbind] %s\n' "$*"
    # 关机阶段 stdout 可能已不可见，同时写入内核日志
    if [[ -w /dev/kmsg ]]; then
        printf 'lecoo-nic-unbind: %s\n' "$*" > /dev/kmsg 2>/dev/null || true
    fi
    return 0
}

list_bound() {
    local d
    for d in "$SYS"/0000:*; do
        [[ -e "$d" ]] && printf '%s\n' "${d##*/}"
    done
}

# bind/unbind 节点是 --w------- root root：非 root 时 shell 会在"打开文件"阶段
# 就报 "权限不够"，且这条错误由 shell 直接输出，printf 的 2>/dev/null 拦不住。
# 因此：① 非 root 自动用 sudo 重入；② 所有写入先判 -w，再在子 shell 里重定向。
require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] && return 0
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -- "$0" "$@"
    fi
    printf '[lecoo-nic-unbind] ERROR: 需要 root 才能写 %s/{bind,unbind}，请用 sudo 运行\n' \
        "$SYS" >&2
    exit 2
}

write_sysfs() {  # $1 = 节点路径, $2 = 要写入的值
    local p="$1" v="$2"
    [[ -e "$p" ]] || { log "WARN  节点不存在：$p"; return 1; }
    [[ -w "$p" ]] || { log "ERROR 无写权限（需 root）：$p"; return 1; }
    # 子 shell 包住重定向，连 shell 自己的重定向错误也一并吞掉
    ( printf '%s' "$v" > "$p" ) 2>/dev/null && return 0
    log "WARN  写入失败：$p"
    return 1
}

cmd_apply() {
    if [[ ! -d "$SYS" ]]; then
        log "skip  ($DRIVER 模块未加载)"
        return 0
    fi
    local ids id ok=0
    ids="$(list_bound)"
    if [[ -z "$ids" ]]; then
        log "keep  (没有已绑定的 $DRIVER 设备)"
        return 0
    fi
    while read -r id; do
        [[ -n "$id" ]] || continue
        if write_sysfs "$SYS/unbind" "$id"; then
            log "unbind $id"
            # 记录到事件日志，便于次日核对"关机钩子是否真的执行了"
            if [[ -x /usr/local/sbin/lecoo-acpi-log ]]; then
                /usr/local/sbin/lecoo-acpi-log event nic_unbind "$id" 2>/dev/null || true
            fi
        else
            log "WARN  unbind 失败：$id"
            ok=1
        fi
    done <<< "$ids"
    return "$ok"
}

cmd_bind() {
    if [[ ! -d "$SYS" ]]; then
        log "WARN  $DRIVER 模块未加载，先 sudo modprobe $DRIVER"
        return 1
    fi
    local d id vid cls found=0
    for d in /sys/bus/pci/devices/0000:*; do
        [[ -e "$d/driver" ]] && continue
        vid="$(cat "$d/vendor" 2>/dev/null || true)"
        cls="$(cat "$d/class" 2>/dev/null || true)"
        [[ "$vid" == "0x10ec" ]] || continue
        [[ "$cls" == "0x020000" ]] || continue
        id="${d##*/}"
        if write_sysfs "$SYS/bind" "$id"; then
            log "bind  $id"
            found=1
        else
            log "WARN  bind 失败：$id"
        fi
    done
    [[ "$found" == "1" ]] || log "keep  (没有待绑定的 Realtek 以太网设备)"
    return 0
}

cmd_status() {
    if [[ ! -d "$SYS" ]]; then
        log "absent $SYS（模块未加载）"
        return 0
    fi
    local ids
    ids="$(list_bound)"
    if [[ -z "$ids" ]]; then
        log "unbound (没有已绑定的 $DRIVER 设备)"
    else
        while read -r id; do
            [[ -n "$id" ]] && log "bound   $id"
        done <<< "$ids"
    fi
}

case "${1:-apply}" in
    apply)  require_root "$@" ; cmd_apply ;;
    bind)   require_root "$@" ; cmd_bind ;;
    status) cmd_status ;;
    *)
        echo "用法: $0 [apply|bind|status]" >&2
        exit 2
        ;;
esac
