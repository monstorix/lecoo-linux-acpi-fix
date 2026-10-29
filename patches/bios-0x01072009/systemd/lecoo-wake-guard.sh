#!/usr/bin/env bash
# lecoo-wake-guard — 在启动时关闭指定的唤醒源（可逆、幂等）
#
# 用途（依据 2026-10-28 实测，BIOS 2.5 / N155A）：
#   * 8042/serio0：与 amd_pmc 的 quirk_spurious_8042 同源（伪 IRQ1 唤醒）。
#     关掉后 **键盘唤醒仍然可用**：本机键盘唤醒走 EC/GPIO（_AEI 的 PBTN, pin 0）
#     → pinctrl(IRQ 7) → Notify(PWRB)，与 i8042 无关（实测 22:35/22:37 各一次）。
#   * GPP2（00:01.3，有线网卡根端口）：/proc/acpi/wakeup 里的 S4 唤醒，会经
#     GPE 0x0F 把系统从 s2idle 拉起（实测 4 次）。同一事件的 GPIO 0x18 路径
#     不归本脚本管，只能靠 ssdt-cpmgpio0 的 _AEI —— rebuild_patch.sh 默认
#     已把 0x0018 改为非唤醒（KEEP_GPIO18_WAKE=1 可保留固件值）。
#   * USB 控制器（XHC0/1/3/4、NHI0）：_AEI 的 pin 0x3A 声明为
#     ExclusiveAndWake，suspend 期间有事件就经 pinctrl(IRQ 7) 拉起系统。
#     2026-10-29 实测：关掉 USB 唤醒后瞬醒源从 pin 0x3A 消失（剩 pin 0x18）；
#     但 /proc/acpi/wakeup 的切换**不跨重启**，每次开机又变回 enabled，
#     因此必须由本服务在启动时重新关闭。
#     关掉 USB 唤醒不影响内置键盘唤醒（走 EC/GPIO 的 PBTN, pin 0），
#     只影响外接 USB 键鼠唤醒——需要时可手工 `restore` 或删除对应项。
#
# 用法：
#   lecoo-wake-guard.sh apply     关闭 TARGETS / ACPI_TARGETS 中的唤醒源（默认）
#   lecoo-wake-guard.sh restore   把它们恢复为 enabled（手工回退用）
#   lecoo-wake-guard.sh status    只打印当前状态，不修改
#
# 设计约束：
#   * 幂等：已是目标状态就跳过，不重复写。
#   * 不写 /etc、不改其它服务、不依赖网络。
#   * 绝不提供自动 restore：如果在关机流程里恢复唤醒源，等于在 S5 前
#     重新武装它们，正是要避免的行为。回退请手工执行 restore。

set -euo pipefail

# 设备级唤醒源（sysfs power/wakeup，写 enabled|disabled，幂等）
TARGETS=(
    /sys/devices/platform/i8042/serio0/power/wakeup
    /sys/devices/platform/i8042/serio1/power/wakeup
)

# ACPI 唤醒源。/proc/acpi/wakeup 是"写名字即切换"的接口，必须按当前状态判断。
ACPI_TARGETS=(
    GPP2
    XHC0
    XHC1
    XHC3
    XHC4
    NHI0
)

log() { printf '[lecoo-wake-guard] %s\n' "$*"; }

read_state() {  # $1 = path -> prints current value or "absent"
    if [[ ! -e "$1" ]]; then
        printf 'absent'
    else
        cat "$1" 2>/dev/null || printf 'unreadable'
    fi
}

apply_one() {
    local f="$1" cur
    cur="$(read_state "$f")"
    case "$cur" in
        absent)     log "skip   (不存在): $f"; return 0 ;;
        unreadable) log "skip   (不可读): $f"; return 0 ;;
        disabled)   log "keep   (已关闭): $f"; return 0 ;;
    esac
    if printf 'disabled' > "$f" 2>/dev/null; then
        log "change (已关闭): $f  $cur -> $(read_state "$f")"
    else
        log "WARN   (写入失败，可能只读): $f"
        return 1
    fi
}

restore_one() {
    local f="$1" cur
    cur="$(read_state "$f")"
    case "$cur" in
        absent|unreadable) log "skip   (不适用): $f"; return 0 ;;
    esac
    if printf 'enabled' > "$f" 2>/dev/null; then
        log "restore(已恢复): $f  $cur -> $(read_state "$f")"
    else
        log "WARN   (写入失败): $f"
        return 1
    fi
}

acpi_state() {  # $1 = name -> enabled | disabled | absent
    local line
    line="$(awk -v n="$1" '$1 == n { print; exit }' /proc/acpi/wakeup 2>/dev/null || true)"
    if [[ -z "$line" ]]; then
        printf 'absent'
    elif [[ "$line" == *"*enabled"* ]]; then
        printf 'enabled'
    else
        printf 'disabled'
    fi
}

acpi_toggle() {  # $1 = name —— 写名字到 /proc/acpi/wakeup 即切换状态
    printf '%s\n' "$1" > /proc/acpi/wakeup 2>/dev/null
}

acpi_apply_one() {
    local n="$1" cur
    cur="$(acpi_state "$n")"
    case "$cur" in
        absent)   log "skip   (不存在): acpi:$n"; return 0 ;;
        disabled) log "keep   (已关闭): acpi:$n"; return 0 ;;
    esac
    if acpi_toggle "$n"; then
        log "change (已关闭): acpi:$n  $cur -> $(acpi_state "$n")"
    else
        log "WARN   (写入失败): acpi:$n"
        return 1
    fi
}

acpi_restore_one() {
    local n="$1" cur
    cur="$(acpi_state "$n")"
    case "$cur" in
        absent)  log "skip   (不存在): acpi:$n"; return 0 ;;
        enabled) log "restore(已是开启): acpi:$n"; return 0 ;;
    esac
    if acpi_toggle "$n"; then
        log "restore(已恢复): acpi:$n  $cur -> $(acpi_state "$n")"
    else
        log "WARN   (写入失败): acpi:$n"
        return 1
    fi
}

mode="${1:-apply}"
case "$mode" in
    apply)
        rc=0
        for f in "${TARGETS[@]}"; do apply_one "$f" || rc=1; done
        for n in "${ACPI_TARGETS[@]}"; do acpi_apply_one "$n" || rc=1; done
        exit "$rc"
        ;;
    restore)
        rc=0
        for f in "${TARGETS[@]}"; do restore_one "$f" || rc=1; done
        for n in "${ACPI_TARGETS[@]}"; do acpi_restore_one "$n" || rc=1; done
        exit "$rc"
        ;;
    status)
        for f in "${TARGETS[@]}"; do log "$(read_state "$f")  $f"; done
        for n in "${ACPI_TARGETS[@]}"; do log "$(acpi_state "$n")  acpi:$n"; done
        ;;
    *)
        echo "用法: $0 [apply|restore|status]" >&2
        exit 2
        ;;
esac
