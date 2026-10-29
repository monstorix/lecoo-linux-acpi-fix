#!/usr/bin/env python3
"""lecoo-acpi-log — 记录每次开机/挂起/关机状态，供后续快速比对。

背景：N155A（BIOS 2.5）排查 s2idle 瞬醒与 S5 偶发重启时，手工跑
`ec-probe.sh wake` 有两个问题：① 关机/重启后全部归零，数据拿不回来；
② 切换会话或终端关闭就断。因此把采集做成常驻钩子，事件追加到
/var/log/lecoo-acpi/events.jsonl（一行一个 JSON，可直接 grep）。

采集点：
  boot     开机后   —— 内核、命令行、覆盖表数量、guard/网卡状态、计数器
  pre      挂起前   —— 计数器快照（存 /run/lecoo-acpi/pre.json）
  post     唤醒后   —— 挂起时长、唤醒 IRQ、GPE/GPIO 增量、instant 判定
  shutdown 关机前   —— 计数器、本轮挂起次数（+ 距下次开机的间隔由 boot 算）
  note     手工备注 —— 例如 `note reboot` / `note clean`
  event    供其它脚本调用（nic-unbind 会写入 nic_unbind）

用法：
  sudo lecoo-acpi-log boot|pre <action>|post <action>|shutdown
  lecoo-acpi-log note "文字"      # 普通用户可用（文件 0644）
  lecoo-acpi-log report           # 汇总表
  lecoo-acpi-log tail 20          # 最近 20 条原始事件
  lecoo-acpi-log path             # 打印日志路径
"""

import datetime
import glob
import json
import os
import platform
import subprocess
import sys
import time

LOG_DIR = os.environ.get("LECOO_LOG_DIR", "/var/log/lecoo-acpi")
EVENTS = os.path.join(LOG_DIR, "events.jsonl")
STATE_DIR = os.environ.get("LECOO_STATE_DIR", "/run/lecoo-acpi")
PRE_FILE = os.path.join(STATE_DIR, "pre.json")
MAX_BYTES = 2_000_000


# ----------------------------------------------------------------- 基础设施
def sh(cmd, timeout=10):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout or ""
    except Exception:
        return ""


def iso(ep=None):
    ep = time.time() if ep is None else ep
    return datetime.datetime.fromtimestamp(ep).astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")


def boot_id():
    try:
        return open("/proc/sys/kernel/random/boot_id").read().strip()
    except Exception:
        return "unknown"


def read_events():
    out = []
    try:
        with open(EVENTS, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except Exception:
                    continue
    except FileNotFoundError:
        pass
    return out


def append(ev):
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
    except Exception as e:
        print(f"[lecoo-acpi-log] 无法创建 {LOG_DIR}: {e}", file=sys.stderr)
        return
    try:
        if os.path.exists(EVENTS) and os.path.getsize(EVENTS) > MAX_BYTES:
            os.replace(EVENTS, EVENTS + ".1")
    except Exception:
        pass
    try:
        with open(EVENTS, "a", encoding="utf-8") as f:
            f.write(json.dumps(ev, ensure_ascii=False, separators=(",", ":")) + "\n")
    except Exception as e:
        print(f"[lecoo-acpi-log] 写入失败: {e}", file=sys.stderr)


def base(event):
    ep = time.time()
    return {"ts": iso(ep), "epoch": round(ep, 3), "event": event, "boot_id": boot_id()}


# ----------------------------------------------------------------- 采集器
def gpe_counts():
    out = {}
    for p in sorted(glob.glob("/sys/firmware/acpi/interrupts/gpe*")):
        name = os.path.basename(p)
        if not name.startswith("gpe") or name == "gpe_all" or len(name) != 5:
            continue
        try:
            first = open(p).read().split()
            n = int(first[0])
        except Exception:
            continue
        if n:
            out[name] = n
    return out


def gpio_counts():
    out = {}
    try:
        lines = open("/proc/interrupts").read().splitlines()
    except Exception:
        return out
    for line in lines:
        parts = line.split()
        if len(parts) > 4 and parts[-1] == "ACPI:Event":
            pin = parts[-2]
            n = sum(int(x) for x in parts[1:-3] if x.isdigit())
            out[pin] = out.get(pin, 0) + n
    return out


def wake_irq():
    try:
        return int(open("/sys/power/pm_wakeup_irq").read().strip())
    except Exception:
        return None


def suspend_stats():
    d = {}
    for k in ("success", "fail", "last_failed_dev", "last_failed_step"):
        try:
            d[k] = open(f"/sys/power/suspend_stats/{k}").read().strip()
        except Exception:
            d[k] = ""
    return d


def guard_state():
    d = {}
    try:
        for line in open("/proc/acpi/wakeup"):
            parts = line.split()
            if len(parts) >= 3 and parts[0] != "Device":
                d[parts[0]] = "enabled" if "*enabled" in line else "disabled"
    except Exception:
        pass
    try:
        d["i8042"] = open("/sys/devices/platform/i8042/serio0/power/wakeup").read().strip()
    except Exception:
        pass
    return d


def nic_state():
    return [os.path.basename(p) for p in glob.glob("/sys/bus/pci/drivers/r8169/0000:*")]


def kmsg_text():
    """优先读内核环形缓冲（dmesg），它不受 journald 刷新延迟影响。

    boot 单元可能在 journald 就绪前运行，post 钩子则在唤醒瞬间运行，
    两者都不该依赖 journal 已落盘——否则会"白跑"（读到空数据）。
    """
    txt = sh(["dmesg"])
    if not txt.strip():
        txt = sh(["journalctl", "-k", "-b", "0", "-o", "cat", "--no-pager"])
    return txt


def table_upgrade_count():
    txt = kmsg_text()
    if not txt.strip():
        # 读不到内核日志（非 root + dmesg_restrict=1）时返回 None，
        # 不能返回 0 —— 否则 report 里会显示"表 0"，把"没读到"伪装成"没加载"。
        return None
    return sum(1 for line in txt.splitlines() if "Table Upgrade" in line)


def last_timekeeping():
    hit = None
    for line in kmsg_text().splitlines():
        if "Timekeeping suspended for" in line:
            hit = line.split("Timekeeping suspended for", 1)[1].strip()
    return hit


def counters():
    return {"gpe": gpe_counts(), "gpio": gpio_counts()}


def diff(old, new, keep_zero=False):
    out = {}
    for k in sorted(set(old) | set(new)):
        d = new.get(k, 0) - old.get(k, 0)
        if d or keep_zero:
            out[k] = d
    return out


# ----------------------------------------------------------------- 子命令
def cmd_boot():
    ev = base("boot")
    ev["kernel"] = platform.release()
    try:
        ev["cmdline"] = open("/proc/cmdline").read().strip()
    except Exception:
        ev["cmdline"] = ""
    ev["table_upgrade"] = table_upgrade_count()
    ev["guard"] = guard_state()
    ev["nic"] = nic_state()
    ev["counters"] = counters()
    prev = [e for e in read_events() if e.get("event") == "shutdown"]
    if prev:
        ev["prev_shutdown_epoch"] = prev[-1]["epoch"]
        ev["gap_s"] = round(ev["epoch"] - prev[-1]["epoch"], 1)
    tail = sh(["journalctl", "-b", "-1", "-k", "-o", "short-iso", "-n", "6", "--no-pager"])
    ev["prev_boot_tail"] = [ln[:160] for ln in tail.splitlines()[-6:]]
    append(ev)


def cmd_pre(action):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
    except Exception:
        pass
    ev = base("suspend_pre")
    ev["action"] = action
    ev["counters"] = counters()
    ev["nic"] = nic_state()
    try:
        with open(PRE_FILE, "w", encoding="utf-8") as f:
            json.dump(ev, f)
    except Exception:
        pass
    append(ev)


def cmd_post(action):
    ev = base("suspend_post")
    ev["action"] = action
    pre = None
    try:
        pre = json.load(open(PRE_FILE, encoding="utf-8"))
    except Exception:
        pre = None
    if pre:
        ev["wall_s"] = round(ev["epoch"] - pre["epoch"], 3)
        cur = counters()
        ev["delta_gpe"] = diff(pre.get("counters", {}).get("gpe", {}), cur["gpe"])
        ev["delta_gpio"] = diff(pre.get("counters", {}).get("gpio", {}), cur["gpio"])
        ev["nic_before"] = pre.get("nic", [])
    ev["timekeeping"] = last_timekeeping()
    ev["wake_irq"] = wake_irq()
    ev["suspend_stats"] = suspend_stats()
    dur = ev.get("wall_s")
    ev["instant"] = bool(dur is not None and dur < 3.0)
    append(ev)


def cmd_shutdown():
    ev = base("shutdown")
    ev["counters"] = counters()
    ev["nic"] = nic_state()
    mine = [e for e in read_events()
            if e.get("boot_id") == ev["boot_id"] and e.get("event") == "suspend_post"]
    ev["suspends"] = len(mine)
    ev["instant_wakes"] = sum(1 for e in mine if e.get("instant"))
    append(ev)


def cmd_note(text):
    ev = base("note")
    ev["text"] = text
    append(ev)


def cmd_event(name, text=""):
    ev = base("event")
    ev["name"] = name
    if text:
        ev["text"] = text
    append(ev)


def fmt_dur(s):
    if s is None:
        return "-"
    if s < 60:
        return f"{s:.1f}s"
    if s < 3600:
        return f"{s/60:.1f}m"
    return f"{s/3600:.1f}h"


def cmd_report(last_n=10):
    evs = read_events()
    if not evs:
        print("还没有任何事件。先安装并启用采集单元（见 patches/bios-0x01072009/systemd/）。")
        return

    boots = []
    cur = None
    for e in evs:
        kind = e.get("event")
        if kind == "boot":
            # 同一 boot_id 的重复 boot 记录（例如手工补跑一次）不产生额外行
            if cur is not None and cur["boot"].get("boot_id") == e.get("boot_id"):
                continue
            cur = {"boot": e, "posts": [], "notes": [], "shutdown": None, "events": []}
            boots.append(cur)
        elif cur is None:
            continue
        elif kind == "suspend_post":
            cur["posts"].append(e)
        elif kind == "shutdown":
            cur["shutdown"] = e
        elif kind == "note":
            cur["notes"].append(e)
        elif kind == "event":
            cur["events"].append(e)

    boots = boots[-last_n:]
    print(f"日志：{EVENTS}\n")
    head = (f"{'开机':<12} {'内核':<16} {'表':>2} {'网卡':<7} "
            f"{'挂起(瞬/总)':<11} {'时长范围':<14} {'关机间隔':<9} 备注")
    print(head)
    print("-" * len(head))
    for i, b in enumerate(boots):
        be = b["boot"]
        kern = be.get("kernel", "?")
        tbl = be.get("table_upgrade")
        tbl = "-" if tbl is None else tbl
        nic = "bound" if be.get("nic") else "unbound"
        posts = b["posts"]
        inst = sum(1 for p in posts if p.get("instant"))
        durs = [p.get("wall_s") for p in posts if p.get("wall_s") is not None]
        rng = f"{min(durs):.1f}-{max(durs):.1f}s" if durs else "-"
        gap = be.get("gap_s")
        gap_s = "-"
        if gap is not None:
            gap_s = fmt_dur(gap) + (" 重启?" if gap < 25 else "")
        note = ",".join(n.get("text", "") for n in b["notes"])
        if b["shutdown"] is None and i != len(boots) - 1:
            note = (note + ",无关机记录").strip(",")
        if b["shutdown"] is not None and not b["shutdown"].get("suspends") and not posts:
            note = (note + ",未睡眠").strip(",")
        print(f"{be.get('ts','')[5:16]:<12} {kern:<16} {tbl:>2} {nic:<7} "
              f"{f'{inst}/{len(posts)}':<11} {rng:<14} {gap_s:<9} {note}")

    details = [p for b in boots for p in b["posts"]]
    if details:
        print("\n最近挂起明细：")
        for p in details[-15:]:
            dg = p.get("delta_gpio") or {}
            dg_s = " ".join(f"gpio{k}:{v:+d}" for k, v in sorted(dg.items())) or "gpio:-"
            ge = p.get("delta_gpe") or {}
            ge_s = " ".join(f"{k}:{v:+d}" for k, v in sorted(ge.items())) or "gpe:-"
            flag = "  << 瞬醒" if p.get("instant") else ""
            print(f"  {p.get('ts','')[5:19]}  {fmt_dur(p.get('wall_s')):>7}  "
                  f"irq={p.get('wake_irq','?')}  {dg_s}  {ge_s}{flag}")

    misc = [e for e in evs if e.get("event") == "event"]
    if misc:
        print("\n其它事件：")
        for e in misc[-10:]:
            print(f"  {e.get('ts','')[5:19]}  {e.get('name','')}  {e.get('text','')}")


def cmd_tail(n=20):
    for e in read_events()[-n:]:
        print(json.dumps(e, ensure_ascii=False))


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    cmd = args[0]
    rest = args[1:]
    if cmd == "boot":
        cmd_boot()
    elif cmd == "pre":
        cmd_pre(rest[0] if rest else "unknown")
    elif cmd == "post":
        cmd_post(rest[0] if rest else "unknown")
    elif cmd == "shutdown":
        cmd_shutdown()
    elif cmd == "note":
        if not rest:
            print("用法: lecoo-acpi-log note <文字>", file=sys.stderr)
            return 2
        cmd_note(" ".join(rest))
    elif cmd == "event":
        cmd_event(rest[0] if rest else "misc", " ".join(rest[1:]))
    elif cmd == "report":
        cmd_report(int(rest[0]) if rest else 10)
    elif cmd == "tail":
        cmd_tail(int(rest[0]) if rest else 20)
    elif cmd == "path":
        print(EVENTS)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
