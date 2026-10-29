#!/usr/bin/env bash
#
# rebuild_patch.sh — Lecoo Pro 14 (N155A) ACPI patch rebuild from a live dump
#
# Rebuilds the whole patch set (DSDT + 3 SSDTs) from a FRESH dump taken on the
# LOCAL machine. This is safe across machines with the same BIOS version,
# because:
#   * structural fixes are applied with address-agnostic anchored edits;
#   * all volatile DRAM addresses (PPIM/OGNV/GNVS/NRSB/TPMB/FTPM/...) and the
#     TPM enablement variables (TPMF/TTDP/...) are inherited automatically from
#     the live dump, exactly as the firmware patched them for THIS boot.
#
# Requirements (host): acpidump, acpixtract, iasl, python3 (+ cpio unless --no-cpio)
# Requirements (target machine):
#   * BIOS version matching EXPECTED_DSDT_REV below (BIOS 2.5 => 0x01072009)
#   * fTPM ENABLED in BIOS setup
#   * ACPI = Auto in BIOS setup (BIOS > Advanced > "ACPI Settings"/"ACPI
#     Support"; Auto or Enabled — never Disabled). Set it BEFORE the next
#     reboot: a non-Auto ACPI mode changes which firmware paths the tables
#     exercise, so dumps and override behaviour from such a boot are not
#     comparable with the validated results.
#   * this patch NOT loaded in the current boot (reboot without
#     acpi_override.cpio first, otherwise the dump will be the patched table)
#
# NOTE (2026-10, revised 2026-10-27): on BIOS 2.5 the firmware already handles
# most issues this patch targets. The earlier claim that ANY override raises
# the shutdown->reboot rate (~18 % -> ~44 %) was never statistically
# significant (3/17 vs 11/25, single-table runs n = 1) and was not
# reproduced: external validation (issue #6) showed a locally rebuilt patch
# applying cleanly on a second 2.5 machine with fTPM and s2idle working,
# while the intermittent shutdown->reboot (~20-50 %) reproduces with the
# patch (and probably without it — the stock baseline there is unmeasured).
# Loading the output on 2.5 is therefore OPTIONAL: reasonable if s2idle
# misbehaves on your unit, pointless otherwise. See
# patches/bios-0x01072009/CHANGES.md ("Update 2026-10-27").
#
# Usage:
#   sudo ./rebuild_patch.sh                    # dump + rebuild + pack cpio
#   sudo ./rebuild_patch.sh --minimal          # ship ONLY ssdt-cpmgpio0
#                                              # (single table edit: pin 0x0018)
#   sudo ./rebuild_patch.sh --dump-only        # only dump and sanity-check
#   sudo ./rebuild_patch.sh --install-acpi     # also copy *.aml to
#                                              # /etc/initcpio/acpi_override
#                                              # (mkinitcpio 'acpi_override' hook / UKI)
#   sudo ./rebuild_patch.sh --install-acpi=DIR # ... to a custom directory
#   sudo ./rebuild_patch.sh --no-cpio          # do not build acpi_override.cpio
#   ./rebuild_patch.sh --ignore-tpm-warning    # proceed even if fTPM looks off
#
# Env knobs (SSDT_ONLY, SSDT_SKIP, PTS_VARIANT, REVERT, OUTPUT_FILE) must be
# passed to sudo, not before it:  sudo REVERT=s3 ./rebuild_patch.sh
#
# WARNING: the script REGENERATES ./patched/*.dsl in place (next to itself).
# Run it from a dedicated copy/directory if you want to keep an existing
# patch set — do not run it inside a checkout you are not ready to have
# rewritten.
#
# Outputs:
#   * acpi_override.cpio in the repo root (unless --no-cpio) — for bootloaders
#     that load a separate initrd BEFORE the main initramfs;
#   * the compiled *.aml stay in ./patched/ (gitignored) — for the mkinitcpio
#     'acpi_override' hook used by UKI setups, or for manual copying.
#     --install-acpi copies them there directly (removing stale tables first).
#
# Reference diffs of the structural changes (for human review) live in
# patches/bios-0x01072009/*.changes.diff. They are NOT applied verbatim —
# the script applies equivalent, address-independent edits.

set -euo pipefail

EXPECTED_DSDT_REV="${EXPECTED_DSDT_REV:-0x01072009}"   # DSDT OEM revision of BIOS 2.5
PATCHED_DSDT_REV="0x0107201A"                          # revision stamped into the override table

# Experimental variants (single-variable diagnostics) — leave unset for the
# normal build:
#   PTS_VARIANT=skip-tpm-s5   -> _PTS does not call \_SB.TPM.TPTS(5) on S5
#                               (keeps SPTS/MPTS/NPTS untouched)
#   PTS_VARIANT=skip-all-s5   -> _PTS skips TPTS/SPTS/MPTS/NPTS on S5
#                               (the old 1.x behaviour)
#   OUTPUT_FILE=<name>        -> output cpio filename (default acpi_override.cpio)
PTS_VARIANT="${PTS_VARIANT:-}"

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
PATCHED_DIR="$REPO_ROOT/patched"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

DUMP_ONLY=0
IGNORE_TPM=0
INSTALL_ACPI=0
NO_CPIO=0
MINIMAL=0
VERSION="v3 (2026-10-28)"
PROFILE="full (DSDT + 3 SSDTs)"
ACPI_DEST="/etc/initcpio/acpi_override"
for arg in "$@"; do
    case "$arg" in
        --dump-only)            DUMP_ONLY=1 ;;
        --ignore-tpm-warning)   IGNORE_TPM=1 ;;
        --install-acpi)         INSTALL_ACPI=1 ;;
        --install-acpi=*)       INSTALL_ACPI=1; ACPI_DEST="${arg#*=}" ;;
        --no-cpio)              NO_CPIO=1 ;;
        --minimal)              MINIMAL=1 ;;
        --help|-h)
            cat <<'USAGE'
Usage: sudo ./rebuild_patch.sh [OPTIONS]

  --minimal               ship only ssdt-cpmgpio0 (single table edit: pin 0x0018)
  --dump-only             dump + sanity-check only, no edits/compile
  --install-acpi[=DIR]    also copy the compiled *.aml to DIR
                          (default: /etc/initcpio/acpi_override)
  --no-cpio               do not build acpi_override.cpio
  --ignore-tpm-warning    proceed even if the fTPM values look wrong
  -h, --help              this text

Env knobs (pass TO sudo):  sudo REVERT=s3,wake ./rebuild_patch.sh
USAGE
            exit 0 ;;
    esac
done

# --minimal: only the table that carries a demonstrated 2.5 fix
# (ssdt-cpmgpio0: _AEI pin 0x0018 non-wake). The DSDT is NOT shipped, so the
# SLPF-based PWRB gating degrades to the plain artifact fix (see SSDT_ONLY).
if [[ "$MINIMAL" == "1" ]]; then
    export SSDT_ONLY=1
    export SSDT_SKIP="${SSDT_SKIP:-wlan,intgpp01}"
    PROFILE="minimal (ssdt-cpmgpio0 only, 1 edit)"
fi

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
for tool in acpidump acpixtract iasl python3; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool (install acpica + iasl package)"
done
if [[ "$NO_CPIO" != "1" ]]; then
    command -v cpio >/dev/null 2>&1 || die "required tool not found: cpio (or pass --no-cpio)"
fi

log "Dumping live ACPI tables..."
if [[ -n "${ACPI_DUMP_FILE:-}" ]]; then
    # Rebuild from a pre-existing acpidump output (no root needed).
    [[ -r "$ACPI_DUMP_FILE" ]] || die "cannot read ACPI_DUMP_FILE=$ACPI_DUMP_FILE"
    cp "$ACPI_DUMP_FILE" "$WORK/acpi.out"
    log "Using provided dump: $ACPI_DUMP_FILE"
elif ! acpidump > "$WORK/acpi.out" 2>"$WORK/acpi.err"; then
    die "acpidump failed (needs root). Re-run with: sudo $0"
fi

cd "$WORK"
acpixtract -a acpi.out >/dev/null

# --------------------------- sanity: the dump must not contain a patched SSDT
# The DSDT marker checks below cannot catch SSDT-only deployments (e.g. after
# --minimal was installed), so scan the raw tables for the debug string that
# our ssdt-cpmgpio0 patch injects. If it is present, this boot still has an
# override loaded and the resulting build would be based on a patched table.
if grep -al "DBG_S2I" ssdt*.dat 2>/dev/null | grep -q .; then
    die "the dumped SSDTs already contain the patch marker (DBG_S2I) — an ACPI override is loaded in this boot.
      Reboot WITHOUT the override (remove acpi_override.cpio / acpi_override hook) and run again."
fi

# acpixtract naming varies across versions; locate files case-insensitively.
shopt -s nocaseglob
dsdt_dat="$(ls dsdt.dat 2>/dev/null | head -n1)"
[[ -n "$dsdt_dat" ]] || die "DSDT not found in acpixtract output"

# ------------------------------------------------------------ BIOS revision
# ACPI header: OEM revision is a little-endian dword at offset 0x18.
dsdt_rev="$(python3 - "$dsdt_dat" <<'PY'
import sys, struct
data = open(sys.argv[1], 'rb').read()
print(f"0x{struct.unpack('<I', data[0x18:0x1C])[0]:08X}")
PY
)"
log "Dumped DSDT OEM revision: $dsdt_rev"
if [[ "$(echo "$dsdt_rev" | tr 'a-f' 'A-F')" != "$(echo "$EXPECTED_DSDT_REV" | tr 'a-f' 'A-F')" ]]; then
    die "BIOS revision mismatch: this patch set targets DSDT OEM revision $EXPECTED_DSDT_REV (BIOS 2.5).
      Update the BIOS first, or set EXPECTED_DSDT_REV=<rev> if you have verified
      the structural edits still apply on your firmware."
fi

# -------------------------------------------------------- disassemble DSDT
iasl -ve -d "$dsdt_dat" >/dev/null
dsdt_dsl="$(ls dsdt.dsl | head -n1)"
[[ -f "$dsdt_dsl" ]] || die "DSDT disassembly failed"

# --------------------------------------------- sanity: pristine, not patched
if grep -q "PTCH0001" "$dsdt_dsl"; then
    die "the dumped DSDT already contains the PTCH0001 marker — this boot has the
      patch loaded. Reboot WITHOUT acpi_override.cpio and re-run this script."
fi
if grep -q "Name (SLPF" "$dsdt_dsl"; then
    die "dumped DSDT contains SLPF — looks like a patched table. Reboot without the patch."
fi

# -------------------------------------- sanity: fTPM runtime values present
tpm_state="$(python3 - "$dsdt_dsl" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
def val(name):
    m = re.search(r'Name \(%s,\s*([^)\n]+)\)' % name, src)
    return m.group(1).strip() if m else None
bad = []
if val('TPMF') != 'One':                          bad.append(f"TPMF={val('TPMF')} (expected One)")
if val('TTDP') != 'One':                          bad.append(f"TTDP={val('TTDP')} (expected One)")
for n in ('TPMB', 'TPMC', 'FTPM', 'PPIM'):
    v = val(n)
    if v is None or v.upper() in ('0xFFFFFFFF', 'ZERO'):
        bad.append(f"{n}={v} (expected a real address)")
if val('AMDT') not in ('One', '0x01', '0x02'):
    bad.append(f"AMDT={val('AMDT')} (unexpected)")
print('\n'.join(bad))
PY
)"
if [[ -n "$tpm_state" ]]; then
    warn "fTPM runtime values look wrong in the dump:"
    warn "$tpm_state"
    warn "Is fTPM enabled in BIOS setup? A dump taken with fTPM disabled will bake"
    warn "those disabled values into the override table and break TPM again."
    [[ "$IGNORE_TPM" == "1" ]] || die "re-dump with fTPM enabled, or pass --ignore-tpm-warning to continue anyway."
fi

if [[ "$DUMP_ONLY" == "1" ]]; then
    log "--dump-only given: dump verified OK, tables left in $WORK (not copied)."
    log "Structural edits and compilation were skipped."
    exit 0
fi

# ------------------------------------------------- pick SSDTs by Table ID
find_ssdt() {  # $1 = OEM Table ID -> prints matching ssdt file(s)
    local want="$1" f tid
    for f in ssdt*.dat; do
        [[ -e "$f" ]] || continue
        tid="$(dd if="$f" bs=1 skip=16 count=8 2>/dev/null | tr -d '\0')"
        [[ "$tid" == "$want" ]] && echo "$f"
    done
    return 0
}

# Only tables we actually MODIFY are overridden. Firmware tables that need no
# change (e.g. GpMsSsdt) are left to the firmware — overriding an unchanged
# table would just add drift risk.
declare -A SSDT_MAP=(
    [WLAN]=ssdt-wlan
    [INTGPP01]=ssdt-intgpp01
    [CPMGPIO0]=ssdt-cpmgpio0
)
for tid in "${!SSDT_MAP[@]}"; do
    matches="$(find_ssdt "$tid")"
    count="$(echo "$matches" | grep -c . || true)"
    [[ "$count" == "1" ]] || die "expected exactly 1 SSDT with OEM Table ID '$tid', found $count"
    base="${SSDT_MAP[$tid]}"
    cp "$matches" "$base.dat"
    iasl -ve -d "$base.dat" >/dev/null
    [[ -f "$base.dsl" ]] || die "disassembly of $tid failed"
    log "SSDT '$tid' -> $base.dsl ($(wc -l < "$base.dsl") lines)"
done

# ----------------------------------------------------- copy into patched/
mkdir -p "$PATCHED_DIR"
rm -f "$PATCHED_DIR"/*.dsl "$PATCHED_DIR"/*.aml
cp "$dsdt_dsl"               "$PATCHED_DIR/dsdt.dsl"
cp ssdt-wlan.dsl             "$PATCHED_DIR/"
cp ssdt-intgpp01.dsl         "$PATCHED_DIR/"
cp ssdt-cpmgpio0.dsl         "$PATCHED_DIR/"

# The kernel only applies an initrd table when its OEM revision is STRICTLY
# greater than the firmware's (drivers/acpi/tables.c:
#   existing_table->oem_revision >= table->oem_revision -> skip).
# Disassembled tables keep the firmware revision, so an SSDT override with the
# same revision is silently ignored (only the DSDT worked because its revision
# was already bumped). Bump every overridden table to firmware_rev + 1.
log "Bumping OEM revisions (kernel requires strictly greater)..."
for base in ssdt-wlan ssdt-intgpp01 ssdt-cpmgpio0; do
    python3 - "$PATCHED_DIR/$base.dsl" "$base.dat" <<'PY'
import re, struct, sys
dsl, dat = sys.argv[1], sys.argv[2]
data = open(dat, 'rb').read(0x1c)
fw_rev = struct.unpack('<I', data[0x18:0x1c])[0]
src = open(dsl).read()
m = re.search(r'(DefinitionBlock \("[^"]*",\s*"SSDT",\s*\d+,\s*"[^"]*",\s*"[^"]*",\s*)0x[0-9A-Fa-f]+', src)
if not m:
    sys.exit(f'cannot locate DefinitionBlock revision in {dsl}')
new = m.group(1) + f'0x{fw_rev + 1:08X}'
open(dsl, 'w').write(src[:m.start()] + new + src[m.end():])
print(f'  [ok]   {dsl}: OEM revision 0x{fw_rev:08X} -> 0x{fw_rev + 1:08X}')
PY
done

# --------------------------------------------------- apply structural edits
log "Applying structural edits (address-agnostic)..."
python3 - "$PATCHED_DIR" "$PATCHED_DSDT_REV" <<'PYEOF'
import re, sys, os

patched, new_rev = sys.argv[1], sys.argv[2]
ssdt_only = os.environ.get('SSDT_ONLY') == '1'
results = []

def edit(fname, name, apply_fn, optional=False):
    path = os.path.join(patched, fname)
    src = open(path).read()
    try:
        new = apply_fn(src)
    except _Skip:
        results.append((fname, name, 'skipped (already applied)'))
        return
    except Exception as e:
        if optional:
            results.append((fname, name, f'skipped (optional, anchor missing)'))
            return
        results.append((fname, name, f'FAILED: {e}'))
        return
    if new is None:
        if optional:
            results.append((fname, name, 'skipped (anchor missing)'))
        else:
            results.append((fname, name, 'FAILED: anchor not found — table layout differs'))
        return
    open(path, 'w').write(new)
    results.append((fname, name, 'ok'))

class _Skip(Exception):
    pass

def rep1(src, old, new):
    n = src.count(old)
    if n == 0:
        return None
    if n != 1:
        raise ValueError(f'anchor matched {n} times, expected 1')
    return src.replace(old, new, 1)

def repn(src, old, new, expect):
    n = src.count(old)
    if n != expect:
        raise ValueError(f'anchor matched {n} times, expected {expect}')
    return src.replace(old, new)

def wrap_skip(old, new):
    def f(src):
        if new in src and old not in src:
            raise _Skip()
        return rep1(src, old, new)
    return f

# ---------------- DSDT ----------------
D = 'dsdt.dsl'
src = open(os.path.join(patched, D)).read()
if 'PTCH0001' in src:
    sys.exit('patched/dsdt.dsl already contains PTCH0001 — regenerate aborted')

# 1. bump override revision so the kernel accepts the table
edit(D, 'DefinitionBlock revision bump', lambda s: re.sub(
    r'(DefinitionBlock \("", "DSDT", 2, "ALASKA", "A M I ", )0x[0-9A-Fa-f]+',
    r'\g<1>' + new_rev, s, count=1))

# 2. normalize guessed external arg counts (cosmetic)
edit(D, 'external _SB_.ALIB annotation', wrap_skip(
    'External (_SB_.ALIB, MethodObj)    // Warning: Unknown method, guessing 2 arguments',
    'External (_SB_.ALIB, MethodObj)    // 2 Arguments'), optional=True)
edit(D, 'external _SB_.WMI_.QEKE annotation', wrap_skip(
    'External (_SB_.WMI_.QEKE, MethodObj)    // Warning: Unknown method, guessing 0 arguments',
    'External (_SB_.WMI_.QEKE, MethodObj)    // 0 Arguments'), optional=True)

# 3. SLPF flag after the externals block
def add_slpf(s):
    if 'Name (SLPF' in s:
        raise _Skip()
    anchor = '    External (PRME, IntObj)\n'
    if s.count(anchor) != 1:
        return None
    return s.replace(anchor, anchor + '\n    Name (SLPF, Zero) // Sleep Flag (0 - awaking, 1 - sleeping)\n', 1)
edit(D, 'Name (SLPF) flag', add_slpf)

# 4. WWAN device node (fixes "ACPI ... device not found" boot errors)
def add_wwan(s):
    if 'Device (WWAN)' in s:
        raise _Skip()
    tail = '            }\n\n            Device (GPP8)\n'
    if s.count(tail) != 1:
        return None
    wwan = ('                Device (WWAN)\n'
            '                {\n'
            '                    Name (_ADR, Zero)\n'
            '                }\n')
    return s.replace(tail, wwan + tail, 1)
edit(D, 'Device (WWAN)', add_wwan)

# 5. GPP0 must not be wake-capable (instant wake fix)
edit(D, 'GPRW(0x16) wake disable', wrap_skip(
    'Return (GPRW (0x16, 0x04))', 'Return (GPRW (0x16, 0x00))'))

# 6. TPM CREI GPIO int -> non-wake
edit(D, 'TPM CREI GpioInt non-wake', wrap_skip(
    'GpioInt (Level, ActiveLow, ExclusiveAndWake, PullNone, 0x0000,\n'
    '                "\\\\_SB.GPIO", 0x00, ResourceConsumer, _Y2A,',
    'GpioInt (Level, ActiveLow, Exclusive, PullNone, 0x0000,\n'
    '                "\\\\_SB.GPIO", 0x00, ResourceConsumer, _Y2A,'))

# 7. NFC1 GPIO ints -> non-wake (4 instances)
def nfc(s):
    old = ('GpioInt (Level, ActiveLow, ExclusiveAndWake, PullNone, 0x0000,\n'
           '                        "\\\\_SB.GPIO", 0x00, ResourceConsumer, ,')
    new = ('GpioInt (Level, ActiveLow, Exclusive, PullNone, 0x0000,\n'
           '                        "\\\\_SB.GPIO", 0x00, ResourceConsumer, ,')
    n = s.count(old)
    if n == 0:
        raise _Skip()
    return repn(s, old, new, n)
edit(D, 'NFC1 GpioInt non-wake', nfc)

# 8. WMI method buffers 0x08 -> 0x10 (buffer overflow fix)
def wmi_buf(s):
    old = 'Local0 = Buffer (0x08){}'
    n = s.count(old)
    if n == 0:
        raise _Skip()
    if n != 11:
        raise ValueError(f'expected 11 WMI buffers, found {n} — table layout changed?')
    return s.replace(old, 'Local0 = Buffer (0x10){}')
edit(D, 'WMI buffer 0x08->0x10', wmi_buf)

# 9. unlock S3
def s3(s):
    if 'Name (_S3, Package' in s:
        raise _Skip()
    return rep1(s, 'Name (XS3, Package (0x04)', 'Name (_S3, Package (0x04)')
edit(D, 'unlock S3 (XS3->_S3)', s3)

# 9b. SS3: advertise S3 wake capability so GPRW resolves to state 3, not 4.
#     Without this, every GPRW-based _PRW keeps arming S4 wake, which can make
#     the EC turn a shutdown into a reboot.
def ss3(s):
    if 'Name (SS3, One)' in s:
        raise _Skip()
    return rep1(s, 'Name (SS3, Zero)', 'Name (SS3, One)')
edit(D, 'SS3 wake mask (S3 capable)', ss3)

# 9c. D0DE is referenced by GPP0.PWSR._OFF but never defined by the 2.5 firmware
#     (the _OFF method aborts with AE_NOT_FOUND during power-resource teardown).
def d0de(s):
    if 'Name (D0DE, Zero)' in s:
        raise _Skip()
    anchor = ('    Scope (_SB.PCI0.GPP0)\n'
              '    {\n'
              '        Name (_S0W, 0x04)  // _S0W: S0 Device Wake State\n')
    if s.count(anchor) != 1:
        return None
    return s.replace(anchor, anchor + '        Name (D0DE, Zero)\n', 1)
edit(D, 'Define D0DE power-resource flag', d0de)

# 10. _PTS: keep the firmware's own sequence EXACTLY as shipped by 2.x
#     (including S5 -> TPTS(5)/SPTS(5)/MPTS(5)/NPTS(5): with fTPM enabled the
#     PSP expects the S5 notification), and only add the SLPF bookkeeping for
#     s2idle. Do NOT port the 1.x "skip everything on S5" workaround: the 1.x
#     dump is a snapshot, not a baseline for 2.x behaviour.
def pts(s):
    if 'Store (One, \\SLPF)' in s:
        raise _Skip()
    anchor = ('    Method (_PTS, 1, NotSerialized)  // _PTS: Prepare To Sleep\n'
              '    {\n')
    if s.count(anchor) != 1:
        return None
    return s.replace(anchor, anchor +
            '        If ((Arg0 == Zero)) { // s2idle: mark sleeping\n'
            '            Store (One, \\SLPF)\n'
            '        }\n'
            '\n', 1)
edit(D, '_PTS s2idle SLPF bookkeeping', pts)

# Experimental: skip the firmware TPM S5 notification (PSP SMI) while keeping
# the rest of the vendor sequence. Used to test whether TPTS(5) causes the
# shutdown->reboot. Enabled with PTS_VARIANT=skip-tpm-s5.
if os.environ.get('PTS_VARIANT') == 'skip-tpm-s5':
    def pts_skip_tpm(s):
        new_form = ('        If (Arg0)\n'
                    '        {\n'
                    '            If ((Arg0 < 0x05))\n')
        if new_form in s:
            raise _Skip()
        old = ('        If (Arg0)\n'
               '        {\n'
               '            \\_SB.TPM.TPTS (Arg0)\n')
        if s.count(old) != 1:
            return None
        repl = ('        If (Arg0)\n'
                '        {\n'
                '            If ((Arg0 < 0x05))\n'
                '            {\n'
                '                \\_SB.TPM.TPTS (Arg0)\n'
                '            }\n'
                '\n')
        return s.replace(old, repl, 1)
    edit(D, 'EXPERIMENT: skip TPTS on S5', pts_skip_tpm)

# Experimental: skip the whole vendor prepare sequence on S5 (old 1.x behaviour).
# Enabled with PTS_VARIANT=skip-all-s5.
if os.environ.get('PTS_VARIANT') == 'skip-all-s5':
    def pts_skip_all(s):
        old = ('        If (Arg0)\n'
               '        {\n'
               '            \\_SB.TPM.TPTS (Arg0)\n'
               '            SPTS (Arg0)\n'
               '            MPTS (Arg0)\n'
               '            \\_SB.PCI0.NPTS (Arg0)\n'
               '        }\n')
        if 'If ((Arg0 < 0x05))\n        {\n            \\_SB.TPM.TPTS' in s:
            raise _Skip()
        if s.count(old) != 1:
            return None
        return s.replace(old, old.replace('        If (Arg0)\n',
                                          '        If ((Arg0 < 0x05))\n'), 1)
    edit(D, 'EXPERIMENT: skip all prepare calls on S5', pts_skip_all)

# 11. _WAK: clear SLPF
def wak(s):
    if 'not DBG_S2I: waking' in s:
        raise _Skip()
    anchor = ('    Method (_WAK, 1, NotSerialized)  // _WAK: Wake\n'
              '    {\n')
    if s.count(anchor) != 1:
        return None
    return s.replace(anchor, anchor +
        '        Debug = "*** not DBG_S2I: waking ***"\n'
        '        Store (Zero, \\SLPF)\n', 1)
edit(D, '_WAK SLPF clear', wak)

# 12. PTCH0001 marker device
def ptch(s):
    if 'PTCH0001' in s:
        raise _Skip()
    body = s.rstrip()
    if not body.endswith('}'):
        return None
    block = (
        '\n'
        '    Scope (_SB)\n'
        '    {\n'
        '        Device (PTCH)\n'
        '        {\n'
        '            Name (_HID, "PTCH0001") // ACPI Patched Marker\n'
        '            Name (_STA, 0x0B)\n'
        '        }\n'
        '    }\n'
        '}')
    return body[:-1].rstrip() + '\n' + block + '\n'
edit(D, 'PTCH0001 marker device', ptch)

# ---------------- ssdt-wlan ----------------
W = 'ssdt-wlan.dsl'
edit(W, 'WLAN externals -> H_EC.XXX3/XXX4', lambda s: s
     .replace('External (_SB_.PCI0.SBRG.EC0_.GPO3, FieldUnitObj)',
              'External (_SB_.PCI0.SBRG.H_EC.XXX3, FieldUnitObj)')
     .replace('External (_SB_.PCI0.SBRG.EC0_.GPOE, FieldUnitObj)',
              'External (_SB_.PCI0.SBRG.H_EC.XXX4, FieldUnitObj)'))
def wlan_body(s):
    old = '\\_SB.PCI0.SBRG.EC0.GPO3'
    n = s.count(old)
    if n == 0:
        raise _Skip()
    return s.replace(old, '\\_SB.PCI0.SBRG.H_EC.XXX3')
edit(W, 'WLAN EC path EC0.GPO3 -> H_EC.XXX3', wlan_body)

# NOTE: S4 wake on GPP2/GPP6 is intentionally left at the firmware default.
# Those states were also present in the previously working 1.x-based build, so
# they are not the shutdown-reboot regression; changing them would alter 2.x
# behaviour (WoWLAN / wake-from-hibernate) without evidence. If the reboot
# still reproduces, test at runtime first:
#   echo GPP6 | sudo tee /proc/acpi/wakeup; echo GPP2 | sudo tee /proc/acpi/wakeup

# ---------------- ssdt-intgpp01 ----------------
def ck17(s):
    old = '        Method (CK17, 0, NotSerialized)\n        {\n            Sleep (100)\n'
    if old in s:
        raise _Skip()
    anchor = '        Method (CK17, 0, NotSerialized)\n        {\n'
    if s.count(anchor) != 1:
        return None
    return s.replace(anchor, anchor + '            Sleep (100)\n', 1)
edit('ssdt-intgpp01.dsl', 'CK17 wake delay Sleep(100)', ck17)

# ---------------- ssdt-cpmgpio0 ----------------
G = 'ssdt-cpmgpio0.dsl'
def slpf_ext(s):
    if 'External (\\SLPF, IntObj)' in s:
        raise _Skip()
    anchor = '    External (_SB_.PWRB, DeviceObj)\n'
    if s.count(anchor) != 1:
        return None
    return s.replace(anchor, anchor + '    External (\\SLPF, IntObj)\n', 1)
if not ssdt_only:
    edit(G, 'declare \\SLPF external', slpf_ext)

for pin in ('0x003D', '0x003E'):
    old = ('GpioInt (Level, ActiveHigh, ExclusiveAndWake, PullNone, 0x0000,\n'
           '                    "\\\\_SB.GPIO", 0x00, ResourceConsumer, ,\n'
           '                    )\n'
           '                    {   // Pin list\n'
           f'                        {pin}\n'
           '                    }')
    new = old.replace('ExclusiveAndWake', 'Exclusive')
    edit(G, f'GPIO {pin} non-wake', wrap_skip(old, new))

# 0x0018 (Edge/ActiveLow) is the GPP2 wake line: _EVT Case(0x18) raises
# Notify(\_SB.PCI0.GPP2, 0x02) + Notify(\_SB.PWRB, 0x80). The GPE 0x0F side of
# the same event can be masked at runtime (/proc/acpi/wakeup GPP2), but this
# GPIO side can only be disarmed in the table — and it did resume s2idle once
# (2026-10-28: pinctrl IRQ 7 + child IRQ 30, with gpe0F frozen). Without this
# edit the only runtime workaround is keeping the wired NIC unbound, which
# costs Ethernet. Enabled by default; set KEEP_GPIO18_WAKE=1 to keep the
# firmware value (e.g. if wake-on-LAN on the wired port is needed).
if os.environ.get('KEEP_GPIO18_WAKE') != '1':
    _old18 = ('GpioInt (Edge, ActiveLow, ExclusiveAndWake, PullNone, 0x0000,\n'
              '                    "\\\\_SB.GPIO", 0x00, ResourceConsumer, ,\n'
              '                    )\n'
              '                    {   // Pin list\n'
              '                        0x0018\n'
              '                    }')
    _new18 = _old18.replace('ExclusiveAndWake', 'Exclusive')
    edit(G, 'GPIO 0x0018 non-wake (GPP2 wake line)', wrap_skip(_old18, _new18))

# EXPERIMENT (opt-in): PBTN (GPIO 0) is the fake power-button line; _AEI adds
# it whenever APBM == One, and _EVT Case(0) then notifies \_SB.PWRB (0x80),
# which logind reports as "Power key pressed short" on every spurious wake.
# PBTN_NONWAKE=1 removes only the wake capability — the pin stays in _AEI, so
# presses are still delivered while the system is running.
# WARNING: after loading, verify the real power button still wakes the system
# from s2idle; if it does not, rebuild without this option.
if os.environ.get('PBTN_NONWAKE') == '1':
    _oldp = ('GpioInt (Edge, ActiveHigh, ExclusiveAndWake, PullDefault, 0x1388,\n'
             '                    "\\\\_SB.GPIO", 0x00, ResourceConsumer, ,\n'
             '                    )\n'
             '                    {   // Pin list\n'
             '                        0x0000\n'
             '                    }')
    _newp = _oldp.replace('ExclusiveAndWake', 'Exclusive')
    edit(G, 'EXPERIMENT: PBTN (GPIO 0) non-wake', wrap_skip(_oldp, _newp))

# rewrite decompiler artifacts + fake-PWRB gating in Case (Zero)
def case_zero(s):
    b1pn_old = ('                        0x56 = CMSR /* External reference */\n'
                '                        Local1\n'
                '                        Local1 += 0x04\n')
    if b1pn_old not in s:
        raise _Skip()
    b1pn_new = ('                        Store (CMSR, Local1)\n'
                '                        Add (Local1, 0x04, Local1)\n')
    s = rep1(s, b1pn_old, b1pn_new)

    pwr_old = ('                        0x56 = CMSR /* External reference */\n'
               '                        Local1\n'
               '                        Local1 += 0x02\n'
               '                        CMSW (0x56, Local1, M460 ("    Notify (\\\\_SB.PWRB, 0x80)\\n", Zero, Zero, Zero, Zero, Zero, Zero))\n'
               '                        Notify (\\_SB.PWRB, 0x80) // Status Change\n')
    pwr_new = ('\n'
               '                        If (LEqual (\\SLPF, Zero))\n'
               '                        {\n'
               '                            Debug = "*** DBG_S2I: not in sleep state, so do some job, whatever ***"\n'
               '                            Store (CMSR, Local1)\n'
               '                            Add (Local1, 0x02, Local1)\n'
               '                            CMSW (0x56, Local1, M460 ("    Notify (\\\\_SB.PWRB, 0x80)\\n", Zero, Zero, Zero, Zero, Zero, Zero))\n'
               '                            Notify (\\_SB.PWRB, 0x80) // Status Change\n'
               '                        }\n'
               '                        Else\n'
               '                        {\n'
               '                            // we are sleeping!\n'
               '                            Debug = "*** DBG_S2I: BLOCKED FAKE PWRB DURING SLEEP! ***"\n'
               '                        }\n')
    return rep1(s, pwr_old, pwr_new)
# Same decompiler-artifact fix, but WITHOUT the \SLPF gating: used when the
# DSDT is not overridden (SSDT_ONLY=1), where \SLPF does not exist.
def case_zero_nogate(s):
    b1pn_old = ('                        0x56 = CMSR /* External reference */\n'
                '                        Local1\n'
                '                        Local1 += 0x04\n')
    if b1pn_old not in s:
        raise _Skip()
    b1pn_new = ('                        Store (CMSR, Local1)\n'
                '                        Add (Local1, 0x04, Local1)\n')
    s = rep1(s, b1pn_old, b1pn_new)

    pwr_old = ('                        0x56 = CMSR /* External reference */\n'
               '                        Local1\n'
               '                        Local1 += 0x02\n')
    pwr_new = ('                        Store (CMSR, Local1)\n'
               '                        Add (Local1, 0x02, Local1)\n')
    return rep1(s, pwr_old, pwr_new)

edit(G, 'Case(0) fake-PWRB gating (SLPF)' if not ssdt_only else 'Case(0) ASL artifact fix only',
     case_zero_nogate if ssdt_only else case_zero)

def evt_dbg(s):
    if 'DBG_S2I: just working, fine!' in s:
        raise _Skip()
    anchor = ('        Method (_EVT, 1, Serialized)  // _EVT: Event\n'
              '        {\n')
    if s.count(anchor) != 1:
        return None
    return s.replace(anchor, anchor +
        '            Debug = "DBG_S2I: just working, fine!"\n', 1)
edit(G, '_EVT debug line', evt_dbg)

# ---------------- experimental reverts (bisect support) ----------------
# REVERT=s3,wmi,wake,d0de  -> undo selected edits after they were applied,
# used to find which change makes the machine reboot instead of powering off.
REVERT = set(x.strip() for x in os.environ.get('REVERT', '').split(',') if x.strip())

def revert(fname, kind):
    path = os.path.join(patched, fname)
    s = before = open(path).read()
    if kind == 's3':
        s = s.replace('Name (_S3, Package (0x04)', 'Name (XS3, Package (0x04)')
        s = s.replace('Name (SS3, One)', 'Name (SS3, Zero)')
    elif kind == 'd0de':
        s = s.replace('        Name (D0DE, Zero)\n', '')
    elif kind == 'wmi':
        s = s.replace('Local0 = Buffer (0x10){}', 'Local0 = Buffer (0x08){}')
    elif kind == 'wake':
        s = s.replace('Return (GPRW (0x16, 0x00))', 'Return (GPRW (0x16, 0x04))')
        s = s.replace('GpioInt (Level, ActiveLow, Exclusive, PullNone, 0x0000,',
                      'GpioInt (Level, ActiveLow, ExclusiveAndWake, PullNone, 0x0000,')
    elif kind == 'devices':
        # only the WWAN node; PTCH stays as the "override active" marker
        s = s.replace('                Device (WWAN)\n'
                      '                {\n'
                      '                    Name (_ADR, Zero)\n'
                      '                }\n', '')
    if s != before:
        open(path, 'w').write(s)
        results.append((fname, f'revert {kind}', 'ok'))
    else:
        results.append((fname, f'revert {kind}', 'FAILED: nothing matched'))

for _kind in sorted(REVERT):
    revert(D, _kind)

# ------------------------------------------------------------ report
failed = 0
for fname, name, status in results:
    mark = '[ok]  ' if status == 'ok' else '[skip]'
    if status.startswith('FAILED'):
        mark = '[FAIL]'
        failed += 1
    print(f'  {mark} {fname:<22} {name:<38} {status}')
if failed:
    sys.exit(f'{failed} structural edit(s) FAILED — table layout differs from expectations; '
             f'compare with patches/bios-0x01072009/*.changes.diff and adapt.')
PYEOF

# ------------------------------------------------------------ compile
log "Compiling tables..."
cd "$PATCHED_DIR"
for f in *.dsl; do
    iasl -ve -sa "$f" || die "compilation of $f failed"
done
rm -f *.asm *.i *.c

# ------------------------------------------------------- roundtrip verify
# Disassemble the compiled DSDT in a scratch dir (never inside patched/ —
# iasl -d would overwrite the .dsl source we must keep).
mkdir -p "$WORK/roundtrip"
cp dsdt.aml "$WORK/roundtrip/"
( cd "$WORK/roundtrip" && iasl -ve -d dsdt.aml >/dev/null )
grep -q "PTCH0001" "$WORK/roundtrip/dsdt.dsl" \
    || die "roundtrip verify failed: PTCH0001 marker missing from compiled DSDT"
if [[ ",${REVERT:-}," != *",s3,"* ]]; then
    grep -q "Name (_S3, Package" "$WORK/roundtrip/dsdt.dsl" \
        || die "roundtrip verify failed: _S3 missing from compiled DSDT"
fi
grep -q "Name (TPMF, One)" "$WORK/roundtrip/dsdt.dsl" \
    || warn "roundtrip check: TPMF is not One in the compiled DSDT — TPM will not work"
log "Roundtrip verification passed."

# ------------------------------------------------- select shipped tables
# SSDT_ONLY=1  -> only the modified SSDTs (the firmware DSDT stays in use)
# SSDT_SKIP=wlan,intgpp01 -> leave those tables to the firmware (per-table bisect)
selected=(*.aml)
if [[ "${SSDT_ONLY:-0}" == "1" ]]; then
    selected=(ssdt-*.aml)
    log "SSDT_ONLY: DSDT deliberately NOT shipped (firmware table stays in use)"
fi
if [[ -n "${SSDT_SKIP:-}" ]]; then
    IFS=',' read -ra _skip_list <<< "$SSDT_SKIP"
    _keep=()
    for _f in "${selected[@]}"; do
        _skip=0
        for _s in "${_skip_list[@]}"; do
            if [[ "$_f" == *"$_s"* ]]; then _skip=1; fi
        done
        (( _skip )) || _keep+=("$_f")
    done
    selected=("${_keep[@]}")
    log "SSDT_SKIP=$SSDT_SKIP applied"
fi
log "Tables: ${selected[*]}"
log "Expected 'Table Upgrade' count: ${#selected[@]}"

# ------------------------------------------------------------ pack cpio
if [[ "$NO_CPIO" == "1" ]]; then
    log "NO_CPIO=1: skipping cpio pack (use --install-acpi for the UKI flow)"
    OUT_FILE="(not built)"
else
    OUT_FILE="${OUTPUT_FILE:-acpi_override.cpio}"
    [[ "$OUT_FILE" = /* ]] || OUT_FILE="$REPO_ROOT/$OUT_FILE"
    log "Packing $(basename "$OUT_FILE")..."
    rm -rf kernel
    mkdir -p kernel/firmware/acpi
    for _f in "${selected[@]}"; do cp "$_f" kernel/firmware/acpi/; done
    find kernel | cpio -H newc --create 2>/dev/null > "$OUT_FILE"
    rm -rf kernel
fi

# ------------------ install into the mkinitcpio 'acpi_override' hook directory
# UKI setups do not load a separate cpio: the hook puts these tables into the
# early uncompressed cpio that mkinitcpio embeds into the UKI.
if [[ "$INSTALL_ACPI" == "1" ]]; then
    if ! mkdir -p "$ACPI_DEST" 2>/dev/null || [[ ! -w "$ACPI_DEST" ]]; then
        die "cannot write to $ACPI_DEST — run with sudo, or use --install-acpi=DIR"
    fi
    rm -f "${ACPI_DEST:?}"/*.aml
    for _f in "${selected[@]}"; do cp "$_f" "$ACPI_DEST"/; done
    log "Installed ${#selected[@]} table(s) to $ACPI_DEST"
    log "Next: add 'acpi_override' to HOOKS in /etc/mkinitcpio.conf, then run: sudo limine-update"
    if [[ -r /etc/mkinitcpio.conf ]] && ! grep -qE '^[[:space:]]*HOOKS=.*\bacpi_override\b' /etc/mkinitcpio.conf; then
        warn "HOOKS in /etc/mkinitcpio.conf has no 'acpi_override' — the tables will NOT be embedded in the initramfs/UKI"
    fi
fi

log "Build: $VERSION — profile: $PROFILE"
log "Compiled tables kept in $PATCHED_DIR (gitignored) for manual use"
log "Done. Output: $OUT_FILE"
echo
echo "===================================================================="
echo "  BEFORE THE NEXT REBOOT — BIOS SETUP (mandatory)"
echo "    Set ACPI = Auto   (BIOS > Advanced > ACPI Settings / ACPI Support)"
echo "    Auto or Enabled is required. Disabled makes every override useless"
echo "    and changes the firmware paths the tables were validated against."
echo "    (The reference test machine already runs with ACPI = Auto.)"
echo "===================================================================="
echo
echo "Post-install checks (after reboot with the tables applied):"
echo "  1. journalctl -b -k | grep 'Table Upgrade'  -> expected: ${#selected[@]} override line(s)"
echo "  2. ls /sys/bus/acpi/devices/ | grep PTCH    -> PTCH0001:00 (only if DSDT is overridden)"
echo "  3. ls /dev/tpm0 /dev/tpmrm0                 -> both present, no 90s boot delay"
echo "  4. shutdown test; suspend (s2idle) test; dmesg | grep DBG_S2I"
