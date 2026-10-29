# 症状对照 — BIOS 2.5 / DSDT OEM `0x01072009`

用途：某项症状复现时，先定位它属于哪条路径，再按对应章节处理。

修复分三部分，互不替代：

- 内核参数——关机变重启；
- 覆盖表——s2idle 瞬醒；
- systemd 服务——残余唤醒源与网卡关机路径。

推导过程见 `CHANGES.md`。

## 诊断前置检查

```bash
journalctl -b -k | grep -c "Table Upgrade"   # 0 = 纯原厂；>0 = 有覆盖生效
grep -o "acpi.ec_no_wakeup=1" /proc/cmdline  # 无输出 = 参数未生效
```

OEM Revision 不严格大于固件时，内核会静默忽略覆盖表。任何"改了没效果"的
判断，先确认上面两条。

## 两项主要症状

| # | 症状 | 自查 | 处理 |
|---|---|---|---|
| 1 | 关机后 1–2 秒自动上电 | `lecoo-acpi-log report` 中上一轮"关机间隔 < 25 s"即疑似 | 触发点在 r8169 驱动的关机路径（D3 / WOL / WAKE#），改表无效。内核参数 `acpi.ec_no_wakeup=1`，配合 `lecoo-nic-unbind.service` 在关机前解绑网卡 |
| 2 | s2idle 约 0.5 秒后恢复 | `./tools/ec-probe.sh wake`：`gpio24` 有增量即此项 | `_AEI` 引脚 `0x0018` 在 AML 中声明为唤醒源，运行时手段（`/proc/acpi/wakeup`、`power/wakeup`、屏蔽 IRQ）均无效，只能改表。按 README 第二步加载最小表 |

## 其他已知现象（均无需改表）

| 现象 | 自查 | 说明与处理 |
|---|---|---|
| `mem_sleep` 只有 s2idle 与 deep | `cat /sys/power/mem_sleep` | 固件将 S3 改名为 `XS3`。不建议切换 `deep`：S3 在此硬件上不可靠，可能无法唤醒 |
| 唤醒后 Wi-Fi 不回来 | `ip -br link show wlan0` | 先 `sudo modprobe -r rtw89_8852be && sudo modprobe rtw89_8852be`，或重启 NetworkManager。仍无效时，可用脚本生成仅含 `ssdt-wlan` 的覆盖表（`SSDT_SKIP` 见脚本头部） |
| 唤醒后 Wi-Fi 恢复偏慢 | `dmesg -T \| grep -i rtw89` 时间戳 | 低优先级。仅当确认与 GP17 恢复时序相关时，生成含 `ssdt-intgpp01` 的覆盖表 |
| 启动日志 `Could not resolve symbol [...GPP7.WWAN]` | `journalctl -b -k \| grep "Could not resolve symbol"` | 本机无 WWAN 模块，固件节点缺失，无功能影响，忽略 |
| 启动日志 `AE_ALREADY_EXISTS [\PMIO] [\SI3R]` | 同上 | 固件重复定义，每次启动恒有，忽略 |
| 启动日志 `Could not resolve symbol [...D1PR._OFF.D0DE]` | `journalctl -b -k \| grep D0DE` | 固件遗漏定义，`_OFF` 中止但无功能影响。如需消除，加入 `dsdt` 覆盖（见 `CHANGES.md`） |
| `AE_AML_BUFFER_LIMIT` / WMI 报错 | `journalctl -b -k \| grep -E "AE_AML_BUFFER_LIMIT\|wmi"` | 2.5 上未出现。若复现，这是需要覆盖 `dsdt` 的场景（WMI 缓冲区 `0x08` → `0x10`，共 11 处） |
| 休眠（S4）后立刻醒来 | `systemctl hibernate`（需 swap） | 本机仅 zram，未配置休眠；配置后再评估 |

## 处理优先级

1. 运行时手段优先：唤醒源（`/proc/acpi/wakeup`）、模块重载、systemd 单元、BIOS 选项。
2. 必须改表时，一次只覆盖一张表：用脚本生成，覆盖前后用
   `journalctl -b -k | grep -c "Table Upgrade"` 核对是否生效。
3. 日志噪音类现象（WWAN、D0DE、AE_ALREADY_EXISTS）不值得改表。

## 当前基线（2026-10-29，参考机）

| 场景 | 结果 |
|---|---|
| 纯原厂，无覆盖表 | s2idle 每次 0.1–0.7 s 即醒 |
| 解绑 r8169 | s2idle 保持 10–25 s；6 轮「挂起 + 关机」全部干净 |
| 最小表 + 网卡绑定 | 20 s / 1375 s / 8.9 s 挂起，全部手动唤醒，`gpio24` 零增量 |
| 最小表 + 网卡绑定，关机 | 仍偶发重启，需 `lecoo-nic-unbind` |

基线随测试更新，最新数据用 `lecoo-acpi-log report` 查看。
