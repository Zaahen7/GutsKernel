# ============================================================================
# susfs-fix.py
#
# Adjusts the SUSFS patch (50_add_susfs_in_gki-android13-5.15.patch) so it
# applies cleanly on a given One UI kernel source tree. Each One UI version
# has its own profile ("oneui<VERSION>"): an ordered list of (old, new) text
# replacements applied to the .patch file.
#
# USAGE
#   python3 susfs-fix.py --oneui VERSION --patch PATH
#
# EXAMPLES
#   python3 susfs-fix.py --oneui "8.5" --patch "path/to/50_add_susfs_in_gki-android13-5.15.patch"
#   python3 susfs-fix.py --oneui "7"   --patch "path/to/50_add_susfs_in_gki-android13-5.15.patch"
#   python3 susfs-fix.py --oneui "6.1" --patch "path/to/50_add_susfs_in_gki-android13-5.15.patch"
#   python3 susfs-fix.py -h
#
# OPTIONS (both are required)
#   --oneui VERSION
#       One UI version to apply: Internally it selects the
#       profile named "oneui<VERSION>" (e.g. "6.1" -> "oneui6.1").
#       A leading "oneui" / "One UI" prefix is accepted and ignored.
#       A profile with no edits defined yet prints a warning and exits
#       without touching the file.
#   --patch PATH
#       Patch file to modify.
#
# BEHAVIOR
#   - Edits run in order; some depend on previous ones.
#   - Each edit replaces only the first occurrence of `old`.
#   - If an edit was already applied, it prints "[Already applied.]" and
#     moves on, so the script is safe to run more than once.
#   - If `old` is not found, it prints the missing text and exits with
#     an error.
#
# WRITING MULTI-LINE EDITS
#   Write one string literal per line, each ending in "\n" except the last,
#   inside parentheses. Python joins them automatically. Lines of the .patch
#   that are diff context start with a single space (" "), so continuation
#   lines look like " \t\tcode...".
#
# ADDING A NEW VERSION
#   Add a new key named "oneui<VERSION>" to PROFILES (e.g. "oneui7").
#   "--oneui 7" becomes valid automatically.
# ============================================================================

import re
import sys
import argparse


def edit(path, old, new):
    with open(path, encoding="utf-8") as f:
        t = f.read()
    if new in t and old not in t:
        print(f"[Already applied.] {path}")
        return
    if old not in t:
        print(f"[ERROR]  {path}:\n{old}")
        sys.exit(1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(t.replace(old, new, 1))
    print(f"[ok] {path}")


# Each profile is an ordered list of (old, new) tuples.
# Order matters: some edits depend on previous ones.
PROFILES = {
    # ---------------- One UI 8.5 ----------------
    "oneui8.5": [
        #EDITSSSS
    ],
    # ---------------- One UI 8 ----------------
    "oneui8": [
        # --- fs/exec.c ---
        # Hunk #1
        ("#include <linux/vmalloc.h>\n #include <linux/io_uring.h>",
         "#include <linux/io_uring.h>"),
        ("#include <linux/syscall_user_dispatch.h>",
         "#include <linux/syscall_user_dispatch.h>\n #include <linux/task_integrity.h>"),

        # --- fs/namespace.c ---
        # Hunk #1
        ("@@ -32,11 +32,21 @@",
         "@@ -32,10 +32,20 @@"),
        ("#include <linux/fs_context.h>\n #include <linux/shmem_fs.h>\n #include <linux/mnt_idmapping.h>",
         "#ifdef CONFIG_KDP_NS\n #include <linux/kdp.h>\n #endif"),
        ('#include "internal.h"\n #include <trace/hooks/blk.h>',
         '#include "internal.h"'),
        # Hunk #9
        ("struct mnt_namespace *copy_mnt_ns(unsigned long flags, struct mnt_namespace *ns,",
         "/* First pass: copy the tree topology */"),
        (
            "\tnew = copy_tree(old, old->mnt.mnt_root, copy_flags);\n"
            " \tif (IS_ERR(new)) {\n"
            " \t\tnamespace_unlock();"
        ,
            "#ifdef CONFIG_KDP_NS\n"
            " \tnew = copy_tree(old, ((struct kdp_mount *)old)->mnt->mnt_root, copy_flags);\n"
            " #else"
        ),

        # --- fs/proc/base.c ---
        # Hunk #1
        ("#include <linux/resctrl.h>\n #include <linux/cn_proc.h>\n #include <linux/cpufreq_times.h>",
         "#include <linux/proca.h>\n #include <linux/cpufreq_times.h>\n #include <linux/cn_proc.h>"),


        # --- fs/proc/task_mmu.c ---
        # Hunk #1
        ("#include <linux/pkeys.h>\n #include <trace/hooks/mm.h>",
         "#include <linux/pkeys.h>"),
        ("#include <asm/tlb.h>",
         "#include <asm/tlb.h>\n #include <asm/tlbflush.h>"),
    ],

    # ---------------- One UI 7 ----------------
    "oneui7": [
        # --- fs/exec.c ---
        # Hunk #1
        ("#include <linux/vmalloc.h>\n #include <linux/io_uring.h>",
         "#include <linux/io_uring.h>"),
        ("#include <linux/syscall_user_dispatch.h>",
         "#include <linux/syscall_user_dispatch.h>\n #include <linux/task_integrity.h>"),
        
        # --- fs/namespace.c ---
        # Hunk #1
        ("@@ -32,11 +32,21 @@",
         "@@ -32,10 +32,20 @@"),
        ("#include <linux/fs_context.h>\n #include <linux/shmem_fs.h>\n #include <linux/mnt_idmapping.h>",
         "#ifdef CONFIG_KDP_NS\n #include <linux/kdp.h>\n #endif"),
        ('#include "internal.h"\n #include <trace/hooks/blk.h>',
         '#include "internal.h"'),
        # Hunk #9
        ("struct mnt_namespace *copy_mnt_ns(unsigned long flags, struct mnt_namespace *ns,",
         "/* First pass: copy the tree topology */"),
        (
            "\tnew = copy_tree(old, old->mnt.mnt_root, copy_flags);\n"
            " \tif (IS_ERR(new)) {\n"
            " \t\tnamespace_unlock();"
        ,
            "#ifdef CONFIG_KDP_NS\n"
            " \tnew = copy_tree(old, ((struct kdp_mount *)old)->mnt->mnt_root, copy_flags);\n"
            " #else"
        ),

        # --- fs/proc/base.c ---
        # Hunk #1
        ("#include <linux/resctrl.h>\n #include <linux/cn_proc.h>\n #include <linux/cpufreq_times.h>",
         "#include <linux/proca.h>\n #include <linux/cpufreq_times.h>\n #include <linux/cn_proc.h>"),

        # --- fs/proc/task_mmu.c ---
        # Hunk #1
        ("#include <linux/pkeys.h>\n #include <trace/hooks/mm.h>",
         "#include <linux/pkeys.h>"),
        ("#include <asm/tlb.h>",
         "#include <asm/tlb.h>\n #include <asm/tlbflush.h>"),
    ],

    # ---------------- One UI 6.1 ----------------
    "oneui6.1": [
        # --- fs/exec.c ---
        # Hunk #1
        ("#include <linux/vmalloc.h>\n #include <linux/io_uring.h>",
         "#include <linux/io_uring.h>"),
        ("#include <linux/syscall_user_dispatch.h>",
         "#include <linux/syscall_user_dispatch.h>\n #include <linux/task_integrity.h>"),
        
        # --- fs/namespace.c ---
        # Hunk #1
        ("@@ -32,11 +32,21 @@",
         "@@ -32,10 +32,20 @@"),
        ("#include <linux/fs_context.h>\n #include <linux/shmem_fs.h>\n #include <linux/mnt_idmapping.h>",
         "#ifdef CONFIG_KDP_NS\n #include <linux/kdp.h>\n #endif"),
        ('#include "internal.h"\n #include <trace/hooks/blk.h>',
         '#include "internal.h"'),
        # Hunk #9
        ("struct mnt_namespace *copy_mnt_ns(unsigned long flags, struct mnt_namespace *ns,",
         "/* First pass: copy the tree topology */"),
        (
            "\tnew = copy_tree(old, old->mnt.mnt_root, copy_flags);\n"
            " \tif (IS_ERR(new)) {\n"
            " \t\tnamespace_unlock();"
        ,
            "#ifdef CONFIG_KDP_NS\n"
            " \tnew = copy_tree(old, ((struct kdp_mount *)old)->mnt->mnt_root, copy_flags);\n"
            " #else"
        ),

        # --- fs/proc/base.c ---
        # Hunk #1
        ("#include <linux/resctrl.h>\n #include <linux/cn_proc.h>\n #include <linux/cpufreq_times.h>",
         "#include <linux/proca.h>\n #include <linux/cpufreq_times.h>\n #include <linux/cn_proc.h>"),

        # --- fs/proc/task_mmu.c ---
        # Hunk #1
        ("#include <linux/pkeys.h>\n #include <trace/hooks/mm.h>",
         "#include <linux/pkeys.h>"),
        ("#include <asm/tlb.h>",
         "#include <asm/tlb.h>\n #include <asm/tlbflush.h>"),
    ],
}

PREFIX = "oneui"
VERSIONS = [name[len(PREFIX):] for name in PROFILES]  # ["8.5", "8", "6.1"]


def oneui_profile(value):
    """Turn the --oneui value into a profile name: '6.1' -> 'oneui6.1'.
    Also accepts 'oneui6.1' and 'One UI 6.1'."""
    v = re.sub(r"^\s*one\s*ui\s*", "", value.strip(), flags=re.IGNORECASE)
    profile = f"{PREFIX}{v}"
    if profile not in PROFILES:
        raise argparse.ArgumentTypeError(
            f"invalid One UI version '{value}' (choose from: {', '.join(VERSIONS)})"
        )
    return profile


def main():
    parser = argparse.ArgumentParser(
        description="Adjust the SUSFS patch for a given One UI version."
    )
    parser.add_argument(
        "--oneui", required=True, type=oneui_profile,
        metavar="VERSION",
        help=f"One UI version to apply ({', '.join(VERSIONS)})",
    )
    parser.add_argument(
        "--patch", required=True,
        help="Path of the .patch file to modify",
    )
    args = parser.parse_args()

    edits = PROFILES[args.oneui]
    if not edits:
        print(f"[WARN] Profile '{args.oneui}' has no edits defined yet.")

    print(f"== Applying profile {args.oneui} to {args.patch} ==")
    for old, new in edits:
        edit(args.patch, old, new)


if __name__ == "__main__":
    main()
