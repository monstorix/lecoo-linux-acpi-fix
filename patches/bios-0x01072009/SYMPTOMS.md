# 症状 → 改动 对照清单（BIOS 2.5 / DSDT OEM `0x01072009`）

用途：日常使用中若某个症状复现，先按下表定位"它对应哪一处改动"，再按"最小修复"的顺序处理。
**默认状态是不加载覆盖表**（2026-10-27 起改为"可选"：s2idle 异常的机器建议加载本机重建的补丁，见 `CHANGES.md` 的 Update 2026-10-27）。

## 诊断前置检查（每次判断前先跑）

```bash
journalctl -b -k | grep -c "Table Upgrade"   # 0 = 纯原厂；>0 = 有覆盖生效
journalctl -b -k | grep "ACPI: DSDT"          # 2.5 原厂应为 00D1ED
```

> 教训：OEM Revision 不严格大于固件时，内核会**静默忽略**覆盖表。任何"改了没效果/有副作用"的判断，必须先确认上面两条。

## 对照表

| # | 症状 | 自查命令 | 对应改动（`rebuild_patch.sh` / diff） | 2.5 原厂实测 | 建议的最小修复 |
|---|---|---|---|---|---|
| 1 | 关机后 1–2 秒自动上电（关机变重启） | 关机后观察；`journalctl -b -1` 的末尾时间与本次 boot 首次日志时间差 ≈10–15 s 即中招 | `_PTS/_WAK/SLPF`、`GPRW(0x16,0)`、`GPP0.D0DE` 等（作者全部动机） | **存在，约 18%（3/17）** | 2026-10-27 修正：~~不要用覆盖表~~——"覆盖把 18% 抬到 44%"无统计显著性（3/17 vs 11/25，单表 n=1），另一台 2.5 机器带补丁约 50% 而原厂基线未测。覆盖与否都会残留；先试 BIOS 选项（ErP / Fast Boot / USB-WLAN Wake），再按 `CHANGES.md` Update 2026-10-27 的 `PTS_VARIANT` 实验定位 |
| 2 | 合盖后几秒内自己醒来（s2idle 即时唤醒） | `journalctl -b -k \| grep -E "PM: suspend (entry\|exit)"`，两条时间差远小于合盖时长 | `ssdt-cpmgpio0` 引脚 0x3D/0x3E 非唤醒、`_EVT` 的 SLPF 门控；DSDT `GPRW(0x16,0x00)` | **正常**（合盖 2 分 20 秒无提前唤醒） | 运行时关唤醒源：`echo GPP0 \| sudo tee /proc/acpi/wakeup`（GPP2/GPP6 同理）。注意：作者本机 s2idle 原厂即正常，但另一台 2.5 机器（issue #6）s2idle 异常且被补丁**完全修复**——若本机也复现即时唤醒，用 `rebuild_patch.sh` 重建覆盖表是合理选项 |
| 3 | 系统只有 s2idle、没有 S3（`deep`） | `cat /sys/power/mem_sleep` | `XS3 → _S3` 解锁、`SS3=One` | **deep 已在列表中**（`[s2idle] deep`），但固件故意改名 `XS3` | 不建议使用 `deep`：固件已锁 S3，切过去可能无法唤醒。若确实需要，先单次实测再决定 |
| 4 | 唤醒后 Wi-Fi 不回来 / 需要手动重连 | `ip -br link show wlan0`；`journalctl -b -k \| grep -i rtw89` | `ssdt-wlan`：`EC0.GPO3` → `H_EC.XXX3`（Wi-Fi 电源时序） | **正常**（原厂 SSDT 对 `EC0.GPO3` 的引用在方法开头即中止，但联网正常） | 先软恢复：`sudo modprobe -r rtw89_8852be && sudo modprobe rtw89_8852be`，或重启 NetworkManager。仍无效才考虑**只覆盖这一张表** |
| 5 | 启动日志出现 `Could not resolve symbol [\_SB.PCI0.GPP7.WWAN]` | `journalctl -b -k \| grep "Could not resolve symbol"` | `Device (WWAN)` 占位节点 | **每次启动 1 次**，无功能影响（本机无 WWAN 模块） | 不建议修：仅为消除日志，收益为零 |
| 6 | `AE_AML_BUFFER_LIMIT` 或 WMI 相关 ACPI 报错 | `journalctl -b -k \| grep -E "AE_AML_BUFFER_LIMIT\|wmi.*fail"` | 11 处 WMI 方法 `Buffer (0x08)` → `0x10` | **未出现** | 若复现：这是**唯一值得用覆盖表**的项，且只需改 DSDT（不含 SSDT） |
| 7 | 启动日志出现 `Could not resolve symbol [\_SB.PCI0.GPP0.D1PR._OFF.D0DE]` 且 `Aborting method ..._OFF` | `journalctl -b -k \| grep D0DE` | `Name (D0DE, Zero)` 定义 | **每次启动 1 次**，`_OFF` 中止；无可观测功能影响 | 不建议修：`D0DE=0` 时 `_OFF` 本身也不做任何事，修它只是消除报错，代价是整表覆盖 |
| 8 | 唤醒后 Wi-Fi 恢复明显偏慢（数秒） | 主观 + `dmesg -T \| grep -i "wlan\|rtw89"` 时间戳 | `ssdt-intgpp01`：`CK17` 加 `Sleep (100)` | 未观察到 | 低优先级；若复现且确定是 GP17 恢复时序问题，可只覆盖这一张表 |
| 9 | 启动日志 `AE_ALREADY_EXISTS [\PMIO] [\SI3R]` | `journalctl -b -k \| grep AE_ALREADY_EXISTS` | 无对应改动 | **每次启动恒有**，属固件重复定义 | 忽略 |
| 10 | 休眠（S4）后立刻醒来 | `systemctl hibernate`（需先配置 swap） | 作者的一条修复动机 | **不适用**：本机只有 zram，未配置休眠 | 若将来配置休眠再评估 |

## 处理优先级（重要）

1. **能用运行时手段解决的，绝不改表**：唤醒源（`/proc/acpi/wakeup`）、模块重载、systemd unit、BIOS 选项。
2. 必须改表时，**一次只覆盖一张表**，并且：
   - 用脚本生成，不要手工打包（`SSDT_ONLY=1` / `SSDT_SKIP=` 见 `rebuild_patch.sh` 头部）；
   - 覆盖前后都用 `journalctl -b -k | grep -c "Table Upgrade"` 核对是否真的生效；
   - 改动后先跑 10 次关机作为回归门槛（本机基线 ≈18%，n=5 没有分辨力）。
3. 只有"造成功能性损失"的症状才值得动表。清单第 5、7、9 项都只是日志噪音，**不建议修**。

## 基线数据（2026-10-25，BIOS 2.5）

| 配置 | 关机次数 | 关机变重启 |
|---|---|---|
| 纯原厂（当前） | 17 | 3（≈18%） |
| DSDT + 3 SSDT | 25 | 11（≈44%） |
| 仅 3 SSDT / 仅 2 SSDT / 仅 1 SSDT | 各 1 | 各 1 |
| DSDT + 3 SSDT（另一台 2.5 机器，issue #6，本机重建） | 未系统统计 | ≈50%（"roughly 50/50"） |

> 2026-10-27 统计学注记：18% vs 44%（3/17 vs 11/25）经 Fisher 精确检验 p≈0.1，**不具统计显著性**；单表消融每次 n=1，无分辨力。"覆盖表加重 S5"的结论已被降级为"未证实"，详见 `CHANGES.md` 的 Update 2026-10-27。最关键的缺失数据是第二台机器的**原厂**基线。

无补丁状态下的其它实测：TPM `/dev/tpm0`、`/dev/tpmrm0` 正常；Wi-Fi(`rtw89_8852be_git`) 正常；蓝牙 `hci0` 正常；s2idle 2 分 20 秒稳定。

## 附录：关机瞬间取证手段的可行性（实测）

| 手段 | 结果 | 说明 |
|---|---|---|
| `pstore/ramoops`（DRAM） | **不可行** | ramoops 可正常注册（`using 0x20000@0x91000000`），但向该保留区写入标记后重启，标记被清除/变乱码 → **固件每次开机重训练/擦除 DRAM**（自检 6.1 s），任何内存持久化都无效 |
| `pstore/efi`（NVRAM） | 待确认 | 需 `efi_pstore.pstore_disable=0 pstore.backend=efi_pstore` 才能注册；注册成功后普通关机仍无记录。删除测试变量时 `rm` 报 `Operation not permitted`，但该错误来自 efivarfs 的 `S_IMMUTABLE` 标志（可用 `chattr -i` 解除），**不等于固件拒绝删除**，需先用 `chattr -i` + `rm` 复测才能定性 |
| ACPI ERST | 不可用 | 固件未提供 ERST 表 |
| netconsole / 串口 | 不可用 | 无第二台接收机、无串口 |

据此，若要捕获"关机最后一秒"，唯一可行路线是 EFI 变量型 pstore；否则日志在 `journald` 退出（关机请求后 2–3 s）处即终止，覆盖不到失败点。
