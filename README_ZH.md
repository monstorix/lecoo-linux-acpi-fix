# Lecoo Pro 14（N155A）ACPI 修复 — BIOS 2.5

[English](README.md) | 简体中文 | [Русский](README_RU.md)

**Lecoo Pro 14（N155A）** 在 **BIOS 2.5**（DSDT OEM revision `0x01072009`）下的 ACPI
表与补丁。

该固件仍存在两项问题：

- **关机偶尔变为重启。** 关机前解绑有线网卡驱动即可避免。
- **s2idle 约 0.5 秒后恢复。** ACPI 表的 `_AEI` 中，引脚 `0x0018` 被声明为唤醒源，
  睡眠期间由网卡触发。此项只能通过修改表解决。

补丁另包含两项 systemd 服务：一项在开机时关闭会重新启用的唤醒源，另一项在关机时解绑网卡
驱动。各项修复互不影响，同时解决两项问题时三部分全部安装。

补丁说明（`CHANGES.md`）与症状对照（`SYMPTOMS.md`）见 `patches/bios-0x01072009/`。

## 开始之前

### BIOS

- **ACPI 设为 Auto**（Advanced → ACPI Settings）。设为 Disabled 时不会加载自定义表。
- **Secure Boot：建议先完成签名配置。** 使用 sbctl 或发行版自带的工具为引导链签名，然后
  按 2a 的钩子方式加载补丁——表位于 initramfs 或 UKI 内部，随镜像一起签名，无需其他操作。
  若使用 2b 的单独 cpio 方式，则按引导器的要求为该文件签名或提供校验和。
- **fTPM 保持开启。** 表由脚本在本机生成，dump 前会确认未加载任何覆盖表，生成的表不影响
  fTPM。
- 若表未生效，关闭 **Fast Boot**；部分固件会保留自己的表副本。

### 确认本机使用的引导与 initramfs 方案

以下步骤适用于 Limine、GRUB、systemd-boot 引导器，以及 mkinitcpio、dracut
initramfs 工具。执行以下命令确认本机使用的组合：

```
test -f /etc/mkinitcpio.conf && echo mkinitcpio
test -f /etc/dracut.conf && echo dracut
ls /boot/loader/entries/*.conf 2>/dev/null && echo systemd-boot
test -f /etc/default/grub && echo grub
test -f /etc/default/limine && echo limine
ls /boot/EFI/Linux/*.efi 2>/dev/null && echo "UKI（统一内核镜像）"
```

`/boot/EFI/Linux/` 下存在 `.efi` 文件时，内核与 initramfs 被打包在同一个已签名镜像中
（UKI）。此时表必须位于该镜像内部，引导器的 initramfs 配置不会起作用。

## 第一步：内核参数

将下列参数加入内核命令行。四项在本文所述的配置中同时使用：

| 参数 | 作用 |
|---|---|
| `acpi.ec_no_wakeup=1` | 将 EC 的 GPE 从唤醒源中移除，影响关机后的自动上电 |
| `acpi_osi="!Windows 2020"` | 不再向固件报告 Windows 2020 支持，固件停留在较早（Windows 10）的电源与待机分支 |
| `acpi=force` | 固件未声明 ACPI 时仍强制启用；多数 UEFI 系统上无可见变化 |
| `i8042.nomux` | 跳过 PS/2 端口复用探测 |

建议四项一并保留，使电源行为与本文配置保持一致。

| 引导器 | 配置文件与条目 | 生效方式 |
|---|---|---|
| Limine | `/etc/default/limine`，`KERNEL_CMDLINE[default]+="..."` | `sudo limine-update` |
| GRUB（Debian、Ubuntu） | `/etc/default/grub`，`GRUB_CMDLINE_LINUX_DEFAULT="..."` | `sudo update-grub` |
| GRUB（Arch） | `/etc/default/grub`，`GRUB_CMDLINE_LINUX_DEFAULT="..."` | `sudo grub-mkconfig -o /boot/grub/grub.cfg` |
| GRUB（Fedora） | `/etc/default/grub`，`GRUB_CMDLINE_LINUX_DEFAULT="..."` | `sudo grub2-mkconfig -o /boot/grub2/grub.cfg` |
| systemd-boot | `/boot/loader/entries/*.conf`，`options ...` 行 | 条目即时生效 |
| systemd-boot，条目由 `kernel-install` 生成 | `/etc/kernel/cmdline` | 修改后重装当前内核，或等待下次内核更新 |

`/boot/limine.conf` 由 `limine-update` 生成，应修改 `/etc/default/limine`，否则下次内核
更新时会被覆盖。

重启后 `cat /proc/cmdline` 中应包含 `acpi.ec_no_wakeup=1`。

## 第二步：生成覆盖表

在目标机器上生成覆盖表，仅覆盖 `ssdt-cpmgpio0`。生成命令按 initramfs 工具选择：

| initramfs 工具 | 生成命令 | 加载方式 |
|---|---|---|
| mkinitcpio（Arch、CachyOS 等） | `sudo ./rebuild_patch.sh --minimal --install-acpi --no-cpio` | 见 2a |
| dracut 及其他 | `sudo ./rebuild_patch.sh --minimal` | 见 2b |

脚本从运行中的固件读取表，将 `_AEI` 中引脚 `0x0018` 的 `ExclusiveAndWake` 改为
`Exclusive`，并将编译结果复制到 `/etc/initcpio/acpi_override/`。脚本同时检查当前是否
已加载覆盖表，否则 dump 得到的是修改后的表，而非固件原始表。

mkinitcpio 路径不生成 cpio，表由钩子直接放入 initramfs；dracut 等工具没有对应钩子，
其命令会在仓库目录下生成 `acpi_override.cpio`。

### 2a. mkinitcpio（Arch、CachyOS 及其衍生版）

mkinitcpio 提供 `acpi_override` 钩子，将 `/etc/initcpio/acpi_override/` 下的 `*.aml`
放入 initramfs 开头的未压缩段，内核最先读取这一段。传统 initramfs 与 UKI 都包含这一段，
两种形态都不需要单独的 `initrd=` 条目。

```
# /etc/mkinitcpio.conf：在现有 HOOKS 行中加入 acpi_override（建议放在 microcode 之后）
# 下面为 CachyOS 默认示例，其余钩子保留你自己的配置
HOOKS=(base systemd autodetect microcode acpi_override kms modconf block keyboard sd-vconsole plymouth filesystems)

sudo mkinitcpio -P          # 重建传统 initramfs
```

使用 UKI 的发行版同样由 mkinitcpio 构建：CachyOS 上经由 `limine-mkinitcpio-hook` 调用
mkinitcpio，钩子的输出会自动包含在镜像中，重建命令为 `sudo limine-update`。通过同类钩子
生成 UKI 的其他发行版，行为与此一致。

目录为空时，钩子会以 `No ACPI table override files found` 停止构建：空目录意味着启动
时不会加载补丁。

<details>
<summary><b>2b. dracut 与其他 initramfs 工具（Fedora、openSUSE 等使用 dracut 的发行版）</b></summary>


dracut 没有对应的钩子，表以单独的非压缩 cpio 形式加载，并排在 initrd 之前。生成方式：

```
sudo ./rebuild_patch.sh --minimal
sudo cp acpi_override.cpio /boot/
```

`acpi_override.cpio` 必须排在主 initramfs **之前**。各引导器的配置方式：

| 引导器 | 配置文件 | 需添加的条目 | 生效方式 |
|---|---|---|---|
| GRUB | `/etc/default/grub` | `GRUB_EARLY_INITRD_LINUX_CUSTOM="acpi_override.cpio"` | 同第一步（按发行版） |
| systemd-boot | `/boot/loader/entries/*.conf` | 在现有 `initrd` 行之前添加 `initrd /acpi_override.cpio` | 条目即时生效 |
| Limine | `/etc/default/limine` | 在 `KERNEL_CMDLINE[default]+=` 开头加入 `initrd=/acpi_override.cpio` | `sudo limine-update` |

由钩子生成的 UKI 按 2a 处理，不使用该 cpio。只有当镜像由手工组装时，才需要把 cpio
列在主 initramfs 之前。

`GRUB_EARLY_INITRD_LINUX_CUSTOM` 中的路径相对于 `/boot`。`/boot` 即为 EFI 系统分区的
系统上，同样使用相对路径。

使用 BLS 条目的发行版（如 Fedora）上，`GRUB_EARLY_INITRD_LINUX_CUSTOM` 可能不生效，请按该发行版的方式把 cpio 放在 initrd 列表最前。

开启 Secure Boot 时，单独加载的 cpio 不在 initramfs 的签名范围内，需要在引导器配置中
提供该文件自己的签名或校验和。因此可用时优先使用 2a 的钩子方式。

</details>

## 第三步：systemd 服务

| 单元 | 作用 |
|---|---|
| `lecoo-wake-guard.service` | 关闭 i8042、GPP2、XHC0/1/3/4、NHI0 的唤醒 |
| `lecoo-nic-unbind.service` | 关机时解绑 `r8169` |

`/proc/acpi/wakeup` 的设置在重启后不保留：唤醒源会在每次开机时重新启用，由第一项服务
关闭。第二项在关机时运行，此时会话已结束，内核尚未关闭驱动。正常使用期间以太网可用。

另有两项单元仅用于记录，将开机、挂起、关机事件写入 `/var/log/lecoo-acpi/events.jsonl`，
`lecoo-acpi-log report` 将其输出为表格。

```
sudo install -m755 patches/bios-0x01072009/systemd/lecoo-wake-guard.sh \
                   patches/bios-0x01072009/systemd/lecoo-nic-unbind.sh /usr/local/sbin/
sudo install -m755 patches/bios-0x01072009/systemd/50-lecoo-acpi-log \
                   /usr/lib/systemd/system-sleep/
sudo install -m644 patches/bios-0x01072009/systemd/*.service /etc/systemd/system/
sudo install -m755 tools/lecoo-acpi-log.py /usr/local/sbin/lecoo-acpi-log

sudo systemctl daemon-reload
sudo systemctl enable --now lecoo-wake-guard lecoo-nic-unbind \
                            lecoo-acpi-log lecoo-acpi-log-shutdown
```

这些单元依赖 systemd 与 `/usr/lib/systemd/system-sleep` 钩子接口。未使用 systemd 的系统
只有第二步的 ACPI 表可用。

## 验证

下次开机后：

```
journalctl -b -k | grep "Table Upgrade"     # 一行：SSDT- AMD-CPMGPIO0
ls /sys/bus/acpi/devices/ | grep PTCH       # 无输出：DSDT 未被替换
grep -E "XHC|NHI|GPP2" /proc/acpi/wakeup    # 全部 *disabled
```

挂起一次并检查计数：

```
./tools/ec-probe.sh wake
```

该命令记录 ACPI 计数、进入挂起，唤醒后输出差值。若计数无变化，且仅按键可以唤醒，说明
表已生效。

## 撤销

<details>
<summary>具体命令</summary>

```
# mkinitcpio（步骤 2a）
sudo sed -i 's/ acpi_override//' /etc/mkinitcpio.conf
sudo rm -f /etc/initcpio/acpi_override/*.aml
sudo mkinitcpio -P          # UKI 则为：sudo limine-update

# 单独 cpio（步骤 2b）
sudo rm -f /boot/acpi_override.cpio
# 删除步骤 2b 中添加的条目，再按第一步的方式重新生成配置

sudo systemctl disable --now lecoo-wake-guard lecoo-nic-unbind \
                            lecoo-acpi-log lecoo-acpi-log-shutdown
```

</details>

## 许可

ACPI 表归各自的所有者。这里的修改仅用于互操作与维修。
