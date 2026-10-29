# Patch audit — BIOS 2.5 (DSDT OEM revision `0x01072009`)

## Principle

The patch is built **against the 2.x firmware**. The `origin/` dump of the
1.x BIOS is a **snapshot of one machine at one boot**, not a behavioural
baseline: values such as `EWPM`, `SS3`, `TPMF`/`PPIM` and the EC default state
differ between BIOS versions and between boots. Therefore:

1. Every edit must either fix a **defect reproduced on 2.x**, or add a feature
   that is **off by default** (so 2.x behaviour is unchanged unless opted in).
2. Where 2.x behaviour is not demonstrably broken, the firmware value is kept.
3. Every deliberate deviation is listed below with a revert procedure and a
   verification method for the 2.x feature it could affect.
4. Never "restore the 1.x default" merely because the 1.x dump had it.

## Edit inventory

Reference diffs: `dsdt.changes.diff`, `ssdt-wlan.changes.diff`,
`ssdt-intgpp01.changes.diff`, `ssdt-cpmgpio0.changes.diff`.

### A. Fixes for defects confirmed on 2.x

| # | File | Change | Evidence on 2.x | Risk |
|---|---|---|---|---|
| A1 | dsdt | `Name (D0DE, Zero)` in `Scope(\_SB.PCI0.GPP0)` | Every 2.x boot logged `Could not resolve symbol [\_SB.PCI0.GPP0.D1PR._OFF.D0DE], AE_NOT_FOUND` and aborted `_OFF` | none (defines what firmware forgot) |
| A2 | dsdt | WMI methods `Local0 = Buffer (0x08){}` → `0x10` (11 sites) | 2.x still has 0x08 buffers; method writes up to 0x10 | none |
| A3 | ssdt-wlan | `\_SB.PCI0.SBRG.EC0.GPO3` → `\_SB.PCI0.SBRG.H_EC.XXX3` | 2.x DSDT has no `EC0` object at all (WLAN power sequencing referenced a non-existent path) | low (makes the path resolvable) |
| A4 | dsdt | `Device (WWAN)` placeholder under GPP7 | 2.x has no WWAN node; author added it to silence "device not found" | low (additive node) |
| A5 | dsdt | `Device (PTCH)` with `_HID "PTCH0001"` | marker only, used by README verification | none |
| A6 | ssdt-cpmgpio0 | `_AEI` pin `0x0018` `ExclusiveAndWake` → `Exclusive` (default on; opt-out `KEEP_GPIO18_WAKE=1`) | 2.5: this is the GPP2 wake line — `_EVT Case(0x18)` does `Notify(\_SB.PCI0.GPP2, 0x02)` + `Notify(\_SB.PWRB, 0x80)`. Captured resuming s2idle in 0.54 s (2026-10-28, pinctrl IRQ 7 + child IRQ 30, `gpe0F` frozen). The GPE 0x0F half of the same event is maskable at runtime (`/proc/acpi/wakeup GPP2`), **this GPIO half is not**; without the edit the only workaround is keeping the wired NIC unbound | removes wired-Ethernet port wake only (RTL8111; WoWLAN unaffected) |

### B. Feature additions carried from the 1.x patch (opt-in / inert by default)

| # | File | Change | Note |
|---|---|---|---|
| B1 | dsdt | `XS3` → `_S3` | exposes S3; default `mem_sleep` stays `s2idle`, so 2.x default behaviour is unchanged. S3 itself is reported as unreliable on this hardware |
| B2 | dsdt | `SLPF` flag + set on `_PTS(0)`, clear on `_WAK` | bookkeeping only, consumed by ssdt-cpmgpio0 |
| B3 | ssdt-cpmgpio0 | block PWRB notify while `SLPF=1` | s2idle instant-wake mitigation (2.x added `APBM` gating around it; both coexist) |
| B4 | ssdt-cpmgpio0 | rewrite `0x56 = CMSR / Local1 / Local1 += ...` decompiler artifacts to `Store`/`Add` | required to compile |
| B5 | ssdt-intgpp01 | `Sleep (100)` in `CK17` | 100 ms delay before GP17 power restore |
| B6 | dsdt | `_WAK` debug string | debug output only |
| B7 | ssdt-cpmgpio0 | `PBTN` (GPIO 0) `ExclusiveAndWake` → `Exclusive` — **opt-in**, `PBTN_NONWAKE=1` | fake power-button line, added to `_AEI` whenever `APBM == One`; spurious wakes show up as `Power key pressed short` in logind. Only the wake capability is removed; the pin stays in `_AEI`, so presses are still delivered while running. **Measured 2026-10-28: on this unit PBTN is the *legitimate* wake path — 3 keyboard wakes produced exactly 3 counts on pin 0 — so this flag is diagnostic only; do not enable it for normal use, or keyboard wake is lost.** |

### C. Deliberate deviations from 2.x defaults (documented trade-offs)

| # | File | 2.x baseline | Patch | Rationale | Revert / verify |
|---|---|---|---|---|---|
| C1 | dsdt | `Return (GPRW (0x16, 0x04))` (GPP0 = NVMe-ish port, S4 wake) | `0x16, 0x00` (resolves to wake state 0) | prevents a PCIe port arming S4 wake at S5; carried from the working 1.x build | revert = restore `0x04`; verify `/proc/acpi/wakeup` GPP0 |
| C2 | dsdt | `SS3 = Zero` | `SS3 = One` | 1.x parity; in 2.x it is a **no-op**: the only `GPRW()` consumer in the DSDT is GPP0 and `DAS3` already forces its result to 0 (no `GPRW()` calls exist in the vendor SSDTs) | zero behavioural impact |
| C3 | dsdt | TPM `CREI` `GpioInt ... ExclusiveAndWake` | `Exclusive` | template not used in CRB mode (TPM IRQ unused) | low |
| C4 | dsdt | NFC1 ×4 `GpioInt ... ExclusiveAndWake` | `Exclusive` | NFC wake is meaningless; reduces spurious wake sources | low; NFC I/O unaffected |
| C5 | dsdt | — | duplicate WMI/external annotation cleanups | compile hygiene | none |

### D. Reverted / rejected (1.x snapshot must not override 2.x)

| Item | Why rejected |
|---|---|
| `_PTS` skipping the S1–S5 prepare sequence (`Arg0 < 0x05`) | 1.x workaround. On 2.x this also skipped `TPM.TPTS(5)` (PSP TPM-memory notification) and `SPTS(5)` (`PWDE`). With fTPM enabled, the PSP now expects that sequence. **Restored to the firmware's own `If (Arg0)` form**, keeping only the `SLPF` bookkeeping. |
| `_PTS` running the prepare sequence for `Arg0 == 0` (s2idle) | 1.x experimental (`// todo: ... idk`). 2.x firmware intentionally does nothing on s2idle. Removed. |
| GpMsSsdt `EWPM 0x01 → 0x00` (disable GPP2 S4 wake) | 2.x deliberately enables it; the same state existed in the previously working 1.x-based build, so it is not the regression. Reverted; firmware table no longer overridden at all. |
| WLAN `GPP6 _PRW` `0x04 → 0x00` | same reasoning as above; would disable wake-from-hibernate/WoWLAN without evidence. Reverted. |
| `SCEN`/`SCUC` EC fields comment-out | 2.x firmware already removed those fields. N/A. |

## Override mechanics (important)

The kernel applies an initrd ACPI table only if **all** of the following hold
(`drivers/acpi/tables.c`):

1. `signature`, `oem_id` (6 B) and `oem_table_id` (8 B) are **byte-identical**
   to the firmware table;
2. the initrd table's `oem_revision` is **strictly greater** than the firmware
   table's (`existing->oem_revision >= table->oem_revision` → skip);
3. the initrd blob passed checksum/length checks at cpio unpack time.

A disassembled + recompiled table keeps the firmware `oem_revision`, so an
SSDT override silently does nothing (only the DSDT was applied historically,
because its revision had been bumped). Symptom: the boot log shows
`ACPI: SSDT ACPI table found in initrd [...]` but **no**
`Table Upgrade: override [SSDT-...]`, and the firmware table is listed with its
original length. At runtime the unpatched SSDT aborts appear, e.g.
`Could not resolve symbol [\_SB.PCI0.SBRG.EC0.GPO3]` →
`Aborting method \_SB.PCI0.GPP6.P_OF`.

`rebuild_patch.sh` therefore bumps every overridden table to
`firmware_oem_revision + 1` before compiling. After installing a rebuilt cpio,
verify with:

```bash
journalctl -b -k | grep -E "Table Upgrade: (override|install)"
# expected: 4 override lines (DSDT + 3 SSDTs)
```

## 2.x feature verification matrix

Run after installing a rebuilt `acpi_override.cpio` (reboot with it loaded):

| Feature | Command / check | Expected |
|---|---|---|
| Patch loaded | `ls /sys/bus/acpi/devices/ \| grep PTCH` | `PTCH0001:00` |
| TPM | `ls /dev/tpm0 /dev/tpmrm0`; `tpm2_getcap properties-fixed` | present, no boot delay |
| Shutdown | 10–20 × `systemctl poweroff`; check boot gap | powers off; next boot only when power button pressed |
| s2idle | `cat /sys/power/mem_sleep` (leave `s2idle`); `systemctl suspend` | sleeps/wakes normally, `dmesg \| grep DBG_S2I` shows the PWRB block messages |
| Hibernate (S4) | only if swap configured: `systemctl hibernate` | resumes; wake-from-S4 still possible via WoL if enabled |
| Wake sources | `cat /proc/acpi/wakeup` | GPP2/GPP6 remain `S4` (2.x default, unchanged by patch) |
| WoL / WoWLAN | `ethtool <eth> \| grep Wake-on`; `iw phy \| grep -i wowlan` | unchanged from bare 2.x |
| WMI / hotkeys | `sudo acpi_listen` + Fn keys, brightness | events arrive, no AE_NOT_FOUND |
| Battery / EC | `upower -i $(upower -e \| grep BAT)`; `sensors` | sane values |
| Wi-Fi power cycle | `rfkill block/unblock wlan` | adapter powers off/on (EC path fix A3) |
| Audio / backlight | volume keys, `brightnessctl` | unchanged |

## Open hypothesis for the occasional shutdown→reboot

The only variable introduced between the working 1.x-based build and the
current build is that **fTPM is now functional**. With `_PTS` restored, the
firmware-side S5 notification (`TPTS(5)`) is back. If the reboot persists:

1. isolate the kernel side without disabling TPM in BIOS (keys stay intact):

   ```bash
   sudo sh -c 'echo -n MSFT0101:00 > /sys/bus/acpi/drivers/tpm_crb/unbind'
   systemctl poweroff
   ```

   (skips `TPM2_Shutdown` for that one shutdown only)

2. if that helps, add a shutdown-time unit that unbinds `tpm_crb`;
3. if not, re-test with GPP2/GPP6 wake disabled at runtime
   (`echo GPP6 | sudo tee /proc/acpi/wakeup`) before considering a DSDT change.

---

## Conclusion (2026-10): no override on BIOS 2.5

> Partly revised on 2026-10-27 after external validation — see
> [Update (2026-10-27)](#update-2026-10-27-external-validation--issue-6) below.

Bisecting the shutdown→reboot regression on a 2.5 machine showed that **the
override mechanism itself, not any individual edit, is what makes it worse**.
Ablation runs (each 5–10 shutdowns, every build verified via
`Table Upgrade` count + DSDT length):

| Configuration | Shutdowns | Reboot instead of power-off |
|---|---|---|
| Stock tables (no override at all) | 17 | 3 (~18 %) |
| DSDT + 3 SSDTs (full patch) | 25 | 11 (~44 %) |
| 3 SSDTs only (stock DSDT) | 1 | 1 |
| 2 SSDTs only (WLAN dropped) | 1 | 1 |
| 1 SSDT only | 1 | 1 |

Everything the patch was written for is already handled by the 2.5 firmware:

| Original issue | 2.5 stock evidence |
|---|---|
| Shutdown → reboot | residual ~18 % (3/17), no ACPI change improved it |
| S3 unlock | `mem_sleep` already shows `[s2idle] deep` (`XS3` rename did not remove S3) |
| WMI buffer overflow | no `AE_AML_BUFFER_LIMIT` / WMI errors in dmesg |
| `ACPI ... device not found` | 0 occurrences (additive `WWAN`/`PTCH` nodes unnecessary) |
| S4 instant wake | hibernation unused (zram swap only) |
| s2idle instant wake | 2 min 20 s suspend with no spurious wake-up |

Consequently the derived "minimal adaptation" is **zero override tables**:
keep the firmware's DSDT and SSDTs, do not load `acpi_override.cpio`.

If a future BIOS reintroduces a spurious wake source, fix it **at runtime**
(`/proc/acpi/wakeup`, `echo GPP0 > /proc/acpi/wakeup`) instead of overriding a
table. `rebuild_patch.sh` and the diffs in this directory remain as the
reference for rebuilding on a new firmware, not as something to load today.

Known methodological trap, for whoever continues this: an ablation is only
valid if the override was actually applied — the kernel silently ignores a
table whose OEM revision is not *strictly greater* than the firmware's. Verify
with `journalctl -b -k | grep -c "Table Upgrade"` before drawing conclusions.

---

## Update (2026-10-27): external validation — [issue #6](https://github.com/LaVashikk/lecoo-linux-acpi-fix/issues/6)

The conclusion above was drawn from a single machine. A second, independent
owner (N155A, BIOS `N155A_00_V2.5_PKID`, CachyOS + Limine) rebuilt the patch
with `rebuild_patch.sh` from **their own dump** and reported:

* all 4 tables applied (`4× Table Upgrade: override`: DSDT + WLAN/INTGPP01/CPMGPIO0);
* fTPM fine: `/dev/tpm0` + `/dev/tpmrm0`, no 90 s boot delay — the earlier
  breakage came from the shared cpio embedding *foreign* DRAM addresses
  (issue #3), exactly the failure mode the local-rebuild workflow prevents;
* s2idle fully fixed: sleeps and wakes properly, no spurious wake-ups;
* shutdown → reboot still reproduces, "roughly 50/50" per
  `systemctl poweroff` — indistinguishable from the with-patch rate here.

What this changes:

1. **The rebuild workflow is validated cross-machine, and the patch is not
   pointless on 2.5.** At minimum the s2idle fix transfers; a locally rebuilt
   cpio no longer breaks fTPM.
2. The "override mechanism raises the reboot rate" claim is **statistically
   weak and now in doubt**: 3/17 vs 11/25 is not significant (Fisher exact
   p ≈ 0.1), and every single-table ablation was n = 1. The missing control
   is the **stock** baseline on the second machine (unmeasured).
3. Revised stance: on 2.5 the override is **optional, not forbidden**. If
   s2idle misbehaves on a given unit, loading the locally rebuilt patch is a
   reasonable fix. The intermittent S5 reboot (~20–50 %) must be expected
   either way until the S5 path is understood.

Open S5 experiments for issue #6 (both already supported by
`rebuild_patch.sh` via `PTS_VARIANT=`):

* measure the **stock** baseline first (remove `initrd=/acpi_override.cpio`,
  then 20–30 × `systemctl poweroff`) — this decides whether the override is a
  factor at all;
* `PTS_VARIANT=skip-tpm-s5` — note that the earlier `tpm_crb` unbind test does
  **not** exonerate `TPTS(5)`: unbinding only stops the kernel-side
  `TPM2_Shutdown`, while `_PTS` still executes the ACPI-side `TPTS(5)` PSP
  notification; the variant removes exactly that call;
* `PTS_VARIANT=skip-all-s5` — the old 1.x behaviour, as a blunt control.
