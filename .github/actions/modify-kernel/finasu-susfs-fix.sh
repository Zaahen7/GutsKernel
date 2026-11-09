#!/usr/bin/env bash
# FinaSU + SUSFS: checks and fixes for GutsKernel (A356E, 5.15)
#
# Usage (KERNEL_DIR must be exported, pointing to the kernel tree root):
#   finasu-susfs-fix.sh pre     before applying 50_add (verifies FinaSU, normalizes guards)
#   finasu-susfs-fix.sh post    after applying 50_add (selinux, sus_path, declarations)
#   finasu-susfs-fix.sh config  writes CONFIG_KSU_SUSFS_* and selects the hook backend
#
# Adapted from scripts/susfs_fixes/apply.sh (reference repo) to this layout:
#   kernel in $KERNEL_DIR (no common/ directory), FinaSU in $KERNEL_DIR/FinaSU
set -euo pipefail

PHASE="${1:?usage: finasu-susfs-fix.sh pre|post|config}"
: "${KERNEL_DIR:?KERNEL_DIR is not set}"

FINASU_KSU="$KERNEL_DIR/FinaSU/kernel"
SUSFS_PATCH="${SUSFS_PATCH:-50_add_susfs_in_gki-android13-5.15.patch}"
SUSFS_DEF_H="$KERNEL_DIR/include/linux/susfs_def.h"

cd "$KERNEL_DIR"

fail() { echo "::error::$*" >&2; exit 1; }
warn() { echo "::warning::$*" >&2; }

SUSFS_OPTS=(
  KSU_SUSFS KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_KSTAT
  KSU_SUSFS_SPOOF_UNAME KSU_SUSFS_ENABLE_LOG KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
  KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG KSU_SUSFS_OPEN_REDIRECT KSU_SUSFS_SUS_MAP
)

# ---------------------------------------------------------------------------
# 1. Verify the FinaSU checkout ships native SUSFS (>= 5b83330b, 2026-10-23)
# ---------------------------------------------------------------------------
verify_finasu_native_susfs() {
  local OPT SYM
  local sha date
  sha="$(git -C "$KERNEL_DIR/FinaSU" rev-parse --short HEAD 2>/dev/null || echo '?')"
  date="$(git -C "$KERNEL_DIR/FinaSU" log -1 --format=%cd --date=short 2>/dev/null || echo '?')"
  echo "FinaSU checkout: $sha ($date)"

  [ -f "$FINASU_KSU/extension/susfs.c" ] || fail \
    "FinaSU $sha ($date) has no native SUSFS (kernel/extension/susfs.c is missing). The selected tag predates 5b83330b (2026-10-23). Use a newer commit/tag."

  for OPT in "${SUSFS_OPTS[@]}"; do
    grep -q "^config $OPT\$" "$FINASU_KSU/Kconfig" \
      || fail "FinaSU Kconfig does not define config $OPT (upstream structure changed)"
  done

  for SYM in ksu_handle_execveat ksu_handle_execveat_sucompat ksu_handle_post_execveat_sucompat; do
    grep -qE "^(int|void) $SYM\(" "$FINASU_KSU/extension/susfs.c" \
      || fail "FinaSU extension/susfs.c does not export $SYM"
  done

  for SYM in ksu_setup_preinit_file ksu_preinit_handle_post_execveat; do
    grep -qE "^(int|void) $SYM\(" "$FINASU_KSU/preinit/preinit.c" 2>/dev/null && continue
    grep -qE "^(int|void) $SYM\(" "$FINASU_KSU/extension/susfs.c" \
      || fail "FinaSU does not export $SYM (checked preinit/preinit.c and extension/susfs.c)"
  done

  grep -q '^int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid)$' "$FINASU_KSU/hook/setuid_hook.c" \
    || fail "FinaSU setuid_hook.c has no 3-argument ksu_handle_setresuid"

  grep -q 'susfs_init();' "$FINASU_KSU/core/init.c" \
    || fail "FinaSU core/init.c does not call susfs_init()"

  # my_* are only used by the 6.6/6.12 patch; a warning is enough on 5.15
  for SYM in my_write_context my_write_access my_setprocattr; do
    grep -qE "^(ssize_t|int) $SYM\(" "$FINASU_KSU/feature/selinux_hide.c" 2>/dev/null \
      || warn "selinux_hide.c does not export $SYM (not needed on 5.15)"
  done

  echo "FinaSU native SUSFS integration: OK"
}

# ---------------------------------------------------------------------------
# 2. PRIORITY_UID_FILTER: the driver does not define the option but calls the functions
# ---------------------------------------------------------------------------
normalize_priority_uid_filter_guard() {
  local f
  [ -f "$SUSFS_PATCH" ] && sed -i -E \
    '/^[+ ]*#[[:space:]]*(ifdef|ifndef|endif).*CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER/ s/CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER/CONFIG_KSU_SUSFS/' \
    "$SUSFS_PATCH"
  for f in fs/susfs.c include/linux/susfs.h; do
    [ -f "$f" ] || continue
    sed -i -E \
      '/^#[[:space:]]*(ifdef|ifndef|endif).*CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER/ s/CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER/CONFIG_KSU_SUSFS/' \
      "$f"
  done
  echo "PRIORITY_UID_FILTER guard normalized to CONFIG_KSU_SUSFS"
}

# ---------------------------------------------------------------------------
# 3. VMA_PAD_START missing on kernels without VMA padding
# ---------------------------------------------------------------------------
fix_vma_pad() {
  if [ -f "$SUSFS_PATCH" ] && grep -qF 'VMA_PAD_START(vma)' "$SUSFS_PATCH" \
     && ! grep -Rqs 'VMA_PAD_START' ./include/linux; then
    echo "Kernel has no VMA_PAD_START: using vma->vm_end in the patch"
    sed -i 's/VMA_PAD_START(vma)/vma->vm_end/g' "$SUSFS_PATCH"
  fi
}

# ---------------------------------------------------------------------------
# 4. New FinaSU selinux_hide (no fake_state): adapt the 5.15 code
# ---------------------------------------------------------------------------
adapt_selinux_new_model() {
  local HIDE="$FINASU_KSU/feature/selinux_hide.c"
  [ -f "$HIDE" ] || { warn "$HIDE not found, skipping selinux adaptation"; return 0; }
  if grep -q 'fake_state' "$HIDE"; then
    echo "FinaSU still has fake_state (old model): nothing to adapt"
    return 0
  fi
  [ -f security/selinux/selinuxfs.c ] || return 0
  if ! grep -q '&fake_state' security/selinux/selinuxfs.c \
     && ! grep -q 'static ssize_t my_write_context' security/selinux/selinuxfs.c; then
    echo "SUSFS patch does not reference fake_state: nothing to adapt"
    return 0
  fi
  echo "New FinaSU model: switching fake_state -> backup_sepolicy + _with_policy (8 args)"

  python3 - <<'PYEOF'
import re, sys

NEW_FS_EXTERNS = (
    "extern struct selinux_policy *backup_sepolicy;\n"
    "extern int security_context_to_sid_with_policy(struct selinux_policy *policy, const char *scontext, u32 scontext_len, u32 *sid, u32 def_sid, gfp_t gfp_flags, u32 *orig_sid_p, int *orig_rc_p);\n"
    "extern int security_sid_to_context_with_policy(struct selinux_policy *policy, u32 sid, char **scontext, u32 *scontext_len);\n"
    "extern void security_compute_av_user_with_policy(struct selinux_policy *policy, u32 ssid, u32 tsid, u16 tclass, struct av_decision *avd);\n"
)
NEW_HK_EXTERNS = (
    "extern struct selinux_policy *backup_sepolicy;\n"
    "extern int security_context_to_sid_with_policy(struct selinux_policy *policy, const char *scontext, u32 scontext_len, u32 *sid, u32 def_sid, gfp_t gfp_flags, u32 *orig_sid_p, int *orig_rc_p);\n"
)

def rd(p): return open(p, encoding="utf-8", errors="surrogateescape").read()
def wr(p, s): open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)

def sub(path, name, old, new):
    s = rd(path)
    n = s.count(old)
    if n != 1:
        print("::warning::%s: %s count=%d (expected 1)" % (path, name, n))
        return
    wr(path, s.replace(old, new, 1))
    print("%s: %s OK" % (path, name))

fs = "security/selinux/selinuxfs.c"
hk = "security/selinux/hooks.c"

sub(fs, "extern", "extern struct selinux_state fake_state;\n", NEW_FS_EXTERNS)
sub(fs, "ctx", "security_context_to_sid(&fake_state, buf, size, &sid, GFP_KERNEL)",
    "security_context_to_sid_with_policy(backup_sepolicy, buf, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL)")
sub(fs, "sid2ctx", "security_sid_to_context(&fake_state, sid, &canon, &len)",
    "security_sid_to_context_with_policy(backup_sepolicy, sid, &canon, &len)")
sub(fs, "scon", "security_context_str_to_sid(&fake_state, scon, &ssid, GFP_KERNEL)",
    "security_context_to_sid_with_policy(backup_sepolicy, scon, strlen(scon), &ssid, SECSID_NULL, GFP_KERNEL, NULL, NULL)")
sub(fs, "tcon", "security_context_str_to_sid(&fake_state, tcon, &tsid, GFP_KERNEL)",
    "security_context_to_sid_with_policy(backup_sepolicy, tcon, strlen(tcon), &tsid, SECSID_NULL, GFP_KERNEL, NULL, NULL)")
sub(fs, "av", "security_compute_av_user(&fake_state, ssid, tsid, tclass, &avd)",
    "security_compute_av_user_with_policy(backup_sepolicy, ssid, tsid, tclass, &avd)")

sub(hk, "extern", "extern struct selinux_state fake_state;\n", NEW_HK_EXTERNS)

s = rd(hk)
s, n61 = re.subn(r"security_context_to_sid\(&fake_state, value, size,\s*\n\s*&sid, GFP_KERNEL\)",
                 "security_context_to_sid_with_policy(backup_sepolicy, value, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL)", s)
s, n15 = re.subn(r"security_context_to_sid\(&fake_state, value, size, &tmp_sid, GFP_KERNEL\)",
                 "security_context_to_sid_with_policy(backup_sepolicy, value, size, &tmp_sid, SECSID_NULL, GFP_KERNEL, NULL, NULL)", s)
print("%s: setprocattr ctx 6.1=%d 5.15=%d" % (hk, n61, n15))
wr(hk, s)

# If a 6-arg extern is left in the patch, raise it to 8 args (idempotent)
for lab, f in (("selinuxfs", fs), ("hooks", hk)):
    t = rd(f)
    t, n2 = re.subn(r"(security_context_to_sid_with_policy\(backup_sepolicy,[^;]*?, GFP_KERNEL)\)(?!, NULL, NULL)", r"\1, NULL, NULL)", t)
    t, nd = re.subn(r"(security_context_to_sid_with_policy\(struct selinux_policy \*policy, const char \*scontext, u32 scontext_len,\s*\n\s*u32 \*sid, u32 def_sid, gfp_t gfp_flags)\);", r"\1, u32 *orig_sid_p, int *orig_rc_p);", t)
    wr(f, t)
    print("%s: 8-arg normalization calls=%d decl=%d" % (lab, n2, nd))

# Permission order (KernelSU df03912f): the current patch already uses should_check_current + fake_error
h = rd(hk)
if "should_check_current" in h and "fake_error = security_context_to_sid_with_policy(backup_sepolicy" in h:
    print("%s: current patch uses should_check_current: permission order already correct" % hk)
else:
    rm = ("\terror = avc_has_perm(&selinux_state,\n\t\t\t\t     mysid, mysid, SECCLASS_PROCESS,\n"
          "\t\t\t\t     PROCESS__SETCURRENT, NULL);\n\n\tif (error)\n\t\treturn error;\n\n")
    if h.count(rm) == 1:
        h = h.replace(rm, "", 1)
        print("%s: rm_early_setcurrent OK" % hk)
    else:
        print("::warning::%s: rm_early_setcurrent did not match" % hk)
    old = ("\t\terror = security_context_to_sid_with_policy(backup_sepolicy, value, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL);\n"
           "\t\tif (error)\n\t\t\treturn error;\n")
    new = ("\t\terror = security_context_to_sid_with_policy(backup_sepolicy, value, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL);\n"
           "\t\tif (error) {\n\t\t\tint perm_error = avc_has_perm(&selinux_state, mysid, mysid, SECCLASS_PROCESS, PROCESS__SETCURRENT, NULL);\n"
           "\t\t\treturn perm_error ?: error;\n\t\t}\n")
    if h.count(old) == 1:
        h = h.replace(old, new, 1)
        print("%s: SETCURRENT order OK" % hk)
    else:
        print("::warning::%s: SETCURRENT order did not match" % hk)
    wr(hk, h)

bad = [f for f in (fs, hk) if "fake_state" in rd(f)]
if bad:
    sys.stderr.write("::error::fake_state is still present in: %s\n" % ", ".join(bad))
    sys.exit(1)
PYEOF
}

# ---------------------------------------------------------------------------
# 5. sus_path: if kern_path fails in the caller namespace, fall back to LOOP
# ---------------------------------------------------------------------------
add_sus_path_loop_fallback() {
  if [ ! -f fs/susfs.c ] || ! grep -qF 'void susfs_add_sus_path(void __user **user_info)' fs/susfs.c; then
    warn "fs/susfs.c has no susfs_add_sus_path: skipping LOOP fallback"
    return 0
  fi
  if grep -qF 'FINASU_SUS_PATH_LOOP_FALLBACK' fs/susfs.c; then
    echo "LOOP fallback already applied"
    return 0
  fi
  python3 - <<'PYEOF'
p = "fs/susfs.c"
s = open(p, encoding="utf-8", errors="surrogateescape").read()
old1 = "void susfs_add_sus_path(void __user **user_info) {"
new1 = "void susfs_add_sus_path_loop(void __user **user_info);\n" + old1
if s.count(old1) != 1:
    print("::warning::susfs_add_sus_path has an unexpected signature, skipping")
    raise SystemExit(0)
s = s.replace(old1, new1, 1)
old2 = ("\tinfo.err = kern_path(info.target_pathname, LOOKUP_FOLLOW, &path);\n"
        "\tif (info.err) {\n"
        "\t\tSUSFS_LOGE(\"failed opening file '%s'\\n\", info.target_pathname);\n"
        "\t\tgoto out_copy_to_user;\n"
        "\t}\n")
new2 = ("\tinfo.err = kern_path(info.target_pathname, LOOKUP_FOLLOW, &path);\n"
        "\tif (info.err) {\n"
        "\t\tSUSFS_LOGE(\"failed opening '%s' in current ns, fallback to sus_path_loop\\n\", info.target_pathname);\n"
        "\t\t/* FINASU_SUS_PATH_LOOP_FALLBACK: FUSE paths (/storage/emulated) do not resolve in the caller namespace */\n"
        "\t\tsusfs_add_sus_path_loop(user_info);\n"
        "\t\treturn;\n"
        "\t}\n")
if s.count(old2) != 1:
    print("::warning::susfs_add_sus_path code differs from expected, skipping fallback")
    raise SystemExit(0)
open(p, "w", encoding="utf-8", errors="surrogateescape").write(s.replace(old2, new2, 1))
print("fs/susfs.c: LOOP fallback applied")
PYEOF
}

# ---------------------------------------------------------------------------
# 6. Declarations/headers the patch leaves out
# ---------------------------------------------------------------------------
fix_missing_decls() {
  if [ -f fs/statfs.c ] && grep -qF 'susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c \
     && [ -f "$SUSFS_DEF_H" ] && ! grep -qF 'susfs_sus_kstat_spoof_vfs_statfs(' "$SUSFS_DEF_H"; then
    echo "Declaring susfs_sus_kstat_spoof_vfs_statfs in susfs_def.h"
    sed -i '/^#endif \/\/ #ifndef KSU_SUSFS_DEF_H$/i struct inode;\nstruct kstatfs;\nextern int susfs_sus_kstat_spoof_vfs_statfs(struct inode *inode, struct kstatfs *buf, bool *is_fuse);' "$SUSFS_DEF_H"
  fi

  if [ -f fs/susfs.c ] && grep -qF 'security_sb_statfs(' fs/susfs.c \
     && ! grep -qF '#include <linux/security.h>' fs/susfs.c; then
    echo "Adding linux/security.h to susfs.c"
    sed -i '0,/^#include <linux\/fs.h>$/s//#include <linux\/fs.h>\n#include <linux\/security.h>/' fs/susfs.c
  fi

  if grep -qF 'vm_flags_clear(new_vma, VM_PAD_MASK);' ./mm/mmap.c 2>/dev/null \
     && ! grep -Rqs 'vm_flags_clear' ./include/linux; then
    sed -i 's/vm_flags_clear(new_vma, VM_PAD_MASK);/new_vma->vm_flags \&= ~VM_PAD_MASK;/' ./mm/mmap.c
    echo "mm/mmap.c: replaced vm_flags_clear (helper missing)"
  fi
}

# ---------------------------------------------------------------------------
# 7. Guard: SUSFS macros used without susfs_def.h
# ---------------------------------------------------------------------------
final_guard() {
  local f
  for f in fs/proc/task_mmu.c fs/namespace.c; do
    [ -f "$f" ] || continue
    if grep -qE 'SUSFS_IS_INODE_|CL_COPY_MNT_NS' "$f" \
       && ! grep -qF '#include <linux/susfs_def.h>' "$f"; then
      fail "$f uses SUSFS macros but does not include linux/susfs_def.h (first hunk rejected)"
    fi
  done
}

# ---------------------------------------------------------------------------
# 8. Config: SUSFS options + hook backend
# ---------------------------------------------------------------------------
write_config() {
  : "${DEFCONFIG:?DEFCONFIG is not set}"
  local OPT
  for OPT in "${SUSFS_OPTS[@]}"; do
    grep -q "^config $OPT\$" "$FINASU_KSU/Kconfig" \
      || fail "FinaSU Kconfig does not define $OPT: olddefconfig would silently drop it"
    "$KERNEL_DIR/scripts/config" --file "$DEFCONFIG" --enable "CONFIG_$OPT"
    echo "Enabled CONFIG_$OPT"
  done

  local CHECK="$FINASU_KSU/tools/check_susfs_inline.sh"
  if grep -q '^config KSU_HOOK_SUSFS_INLINE' "$FINASU_KSU/Kconfig" 2>/dev/null \
     && [ -f "$CHECK" ] && bash "$CHECK" "$KERNEL_DIR" >/dev/null 2>&1; then
    "$KERNEL_DIR/scripts/config" --file "$DEFCONFIG" --enable CONFIG_KSU_HOOK_SUSFS_INLINE
    echo "Hook backend: SUSFS Inline"
  else
    warn "Inline hook call sites (or check_susfs_inline.sh) missing: FinaSU will use the Tracepoint backend"
  fi
}

case "$PHASE" in
  pre)
    verify_finasu_native_susfs
    normalize_priority_uid_filter_guard
    fix_vma_pad
    ;;
  post)
    adapt_selinux_new_model
    add_sus_path_loop_fallback
    fix_missing_decls
    final_guard
    ;;
  config)
    write_config
    ;;
  *) fail "unknown phase: $PHASE (pre|post|config)" ;;
esac
