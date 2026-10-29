# Patch notes — BIOS 2.5 (DSDT OEM revision `0x01072009`)

## Principle

- The patch is built against the 2.5 firmware. Only defects reproduced on 2.5
  are fixed; where 2.5 behaviour is not demonstrably broken, the firmware value
  is kept.
- Nothing is restored merely because the 1.x dump had it.
- Every deviation is listed below with its revert and verification.

Reference diffs: `dsdt.changes.diff`, `ssdt-wlan.changes.diff`,
`ssdt-intgpp01.changes.diff`, `ssdt-cpmgpio0.changes.diff`.

## The edit `--minimal` ships

| File | Change | Why |
|---|---|---|
| ssdt-cpmgpio0 | `_AEI` pin `0x0018`: `ExclusiveAndWake` → `Exclusive` (opt-out `KEEP_GPIO18_WAKE=1`) | pin `0x0018` is the GPP2 (RTL8111) wake line; during suspend the NIC's D3 transition drives it and wakes the machine. `_EVT Case(0x18)` does `Notify(GPP2, 0x02)` + `Notify(PWRB, 0x80)`. The GPE 0x0F half of the event can be masked at runtime (`/proc/acpi/wakeup GPP2`), this GPIO half cannot. Risk: removes wired-Ethernet wake only |

The same SSDT also rewrites decompiler artifacts (`0x56 = CMSR / Local1 / ...`)
to `Store`/`Add` so the table compiles; no behavioural change.

## Further edits available in the script (not shipped by `--minimal`)

These target defects known from 2.5 boots. Each one is inactive unless the
corresponding table is overridden.

| File | Change | Note |
|---|---|---|
| dsdt | `Name (D0DE, Zero)` under `Scope(\_SB.PCI0.GPP0)` | every 2.5 boot logs `Could not resolve symbol [...D1PR._OFF.D0DE]`; cosmetic |
| dsdt | WMI `Buffer (0x08)` → `0x10` (11 sites) | no `AE_AML_BUFFER_LIMIT` observed on 2.5 |
| dsdt | `Device (WWAN)` placeholder | silences a log line only |
| dsdt | `Device (PTCH)` marker | verification helper |
| ssdt-wlan | `EC0.GPO3` → `H_EC.XXX3` | the 2.5 DSDT has no `EC0` object; Wi-Fi power sequencing |
| ssdt-intgpp01 | `Sleep (100)` in `CK17` | GP17 power-restore delay |
| dsdt | `XS3` → `_S3`, `SLPF` flag, `GPRW(0x16,0x04)` → `0x00` | 1.x carry-over set; S3 is unreliable on this hardware, s2idle is the default |

Opt-in knobs in `rebuild_patch.sh`: `PBTN_NONWAKE=1` (do **not** use — pin 0 is
the keyboard wake path on this unit), `KEEP_GPIO18_WAKE=1`, `PTS_VARIANT`,
`SSDT_SKIP`, `REVERT`.

## Override mechanics

The kernel applies an initrd ACPI table only if **all** of the following hold
(`drivers/acpi/tables.c`):

1. `signature`, `oem_id` and `oem_table_id` are **byte-identical** to the
   firmware table;
2. the initrd table's `oem_revision` is **strictly greater** than the firmware
   table's;
3. the blob passed the cpio checksum/length checks.

A disassembled and recompiled table keeps the firmware `oem_revision`, so the
override silently does nothing: the boot log shows
`ACPI: SSDT ACPI table found in initrd [...]` but **no** `Table Upgrade` line.
`rebuild_patch.sh` therefore bumps every overridden table to
`firmware_oem_revision + 1` before compiling. Verify after rebooting:

```bash
journalctl -b -k | grep "Table Upgrade"
# --minimal: exactly one line — SSDT- AMD-CPMGPIO0
```

## Conclusions (2026-10-29)

### s2idle instant wake = `_AEI` pin 0x0018

`\_SB.GPIO._AEI` (inside `ssdt-cpmgpio0`) declares pin `0x0018` — the RTL8111
wake line — as `GpioInt (Edge, ActiveLow, ExclusiveAndWake, ...)`. The NIC's D3
transition during suspend drives that line; the interrupt arrives via the
pinctrl (IRQ 7, `amd_gpio 24  ACPI:Event`) and wakes the system after
0.1–0.7 s.

Runtime measures that do **not** stop it (each tried and measured):

| Attempt | Result |
|---|---|
| `GPP2` disabled in `/proc/acpi/wakeup` | kills only GPE 0x0F; `gpio24` keeps counting |
| device `power/wakeup=disabled` on `00:01.3` and `0c:00.0` | no effect on the GPIO line |
| disabling USB wake (`XHC*`, `NHI0`) | removes the second source (pin 0x3A), pin 0x18 remains |
| masking the IRQ | the pin is armed from the AML, not from the IRQ layer |

The table edit (`0x0018` → `Exclusive`) removes it. Without the table, the
workaround is unbinding `r8169` — same effect, but Ethernet is lost.

### The S5 reboot is not caused by the wake event

With `r8169` unbound, six shutdowns were clean, three of them right after an
instant wake. With the NIC bound and the minimal table loaded, occasional
shutdown→reboot still occurs. The instant wake and the S5 reboot are therefore
independent, and the factor for S5 is the r8169 shutdown path (D3 / WOL /
WAKE#), not the ACPI wake declaration. `lecoo-nic-unbind.service` is the fix
for S5; the table is the fix for s2idle.

### Kernel parameters

| Parameter | Effect |
|---|---|
| `acpi.ec_no_wakeup=1` | removes the EC GPE from the wake sources; affects the power-on after shutdown |
| `acpi_osi="!Windows 2020"` | the firmware stays on the earlier (Windows 10) power and standby path |
| `acpi=force` | keeps ACPI enabled when the firmware does not announce it |
| `i8042.nomux` | skips PS/2 port multiplexing detection |

### Deployment

| Part | Fixes | Cannot fix |
|---|---|---|
| kernel cmdline | S5 | s2idle instant wake |
| minimal table (`--minimal`) | s2idle instant wake | S5 |
| guard units | residual wake sources + S5 NIC path | — |

Still open: the shutdown count for `lecoo-nic-unbind` (collected with
`lecoo-acpi-log report`), and the EC-GPE event burst during normal operation
(~4–10/s; absent during sleep, so it does not affect s2idle residency).

## History

- 2026-10-25 — a "zero override" conclusion was drawn from ablation runs
  (18 % vs 44 %). Voided on 2026-10-29: the sample was too small, and the
  instant wake and the shutdown reboot were conflated in the same runs.
- 2026-10-27 — external validation through
  [issue #6](https://github.com/LaVashikk/lecoo-linux-acpi-fix/issues/6): a
  second 2.5 owner rebuilt the patch from their own dump; fTPM and s2idle
  worked, which established the local-rebuild workflow as the requirement.
  The full text of both entries is in the git history.
