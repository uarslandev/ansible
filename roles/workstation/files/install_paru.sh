#!/usr/bin/env python3
"""
Package Synchronization Utility for Arch Linux & Ansible

Audits and synchronizes Arch Linux packages (pacman repo & AUR via paru)
with the Ansible group_vars/workstations.yml package manifest.

Usage:
  pkg-sync                          Display package drift between system and Ansible config
  pkg-sync --check                  Check for package drift (exit code 1 if drift exists)
  pkg-sync --apply                  Update group_vars/workstations.yml to match installed system packages
  pkg-sync --interactive            Interactively approve/reject package additions and removals
  pkg-sync --add <pkg>              Add a package to workstations.yml (auto-detects pacman vs AUR)
  pkg-sync --remove <pkg>           Remove a package from workstations.yml
  pkg-sync --config <path>          Path to group_vars/workstations.yml
"""

import sys
import argparse
import subprocess
import pathlib
import yaml

# ANSI Color formatting
GREEN = "\033[32m"
RED = "\033[31m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
BOLD = "\033[1m"
RESET = "\033[0m"


def find_config_path(override_path=None):
    if override_path:
        path = pathlib.Path(override_path).resolve()
        if path.exists():
            return path
        sys.exit(f"{RED}Error:{RESET} Specified config path does not exist: {override_path}")

    candidates = [
        pathlib.Path.cwd() / "group_vars" / "workstations.yml",
        pathlib.Path(__file__).resolve().parent.parent / "group_vars" / "workstations.yml",
        pathlib.Path.home() / "ansible" / "group_vars" / "workstations.yml",
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate.resolve()

    sys.exit(f"{RED}Error:{RESET} Could not locate group_vars/workstations.yml. Use --config to specify path.")


def load_config(config_path):
    with open(config_path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    data.setdefault("system_packages", [])
    data.setdefault("aur_packages", [])
    data.setdefault("devops_tool_versions", {})
    return data


def save_config(config_path, data):
    system_packages = sorted(list(set(data.get("system_packages", []))))
    aur_packages = sorted(list(set(data.get("aur_packages", []))))
    devops_tool_versions = data.get("devops_tool_versions", {})

    lines = [
        "---",
        "# Packages installed via pacman on Arch Linux workstations",
        "system_packages:",
    ]
    for pkg in system_packages:
        lines.append(f"  - {pkg}")

    lines.append("")
    lines.append("# AUR packages installed via paru (when available)")
    lines.append("aur_packages:")
    if aur_packages:
        for pkg in aur_packages:
            lines.append(f"  - {pkg}")
    else:
        lines.append("  []")

    lines.append("")
    lines.append("# Versions for standalone DevOps tools")
    lines.append("devops_tool_versions:")
    for k, v in devops_tool_versions.items():
        lines.append(f'  {k}: "{v}"')
    lines.append("")

    content = "\n".join(lines)
    with open(config_path, "w", encoding="utf-8") as f:
        f.write(content)


def get_working_pkg_cmd():
    if subprocess.run(["which", "paru"], capture_output=True).returncode == 0:
        if subprocess.run(["paru", "--version"], capture_output=True, text=True).returncode == 0:
            return "paru"
    return "pacman"


def get_installed_packages():
    cmd_bin = get_working_pkg_cmd()

    try:
        native = set(subprocess.check_output([cmd_bin, "-Qnq"], text=True).splitlines())
    except Exception:
        native = set()

    try:
        aur = set(subprocess.check_output([cmd_bin, "-Qmq"], text=True).splitlines())
    except Exception:
        aur = set()

    return native, aur


def is_aur_package(pkg):
    cmd_bin = get_working_pkg_cmd()
    try:
        res = subprocess.run([cmd_bin, "-Qm", pkg], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        return res.returncode == 0
    except Exception:
        return False


def is_installed_package(pkg):
    cmd_bin = get_working_pkg_cmd()
    try:
        res = subprocess.run([cmd_bin, "-Q", pkg], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        return res.returncode == 0
    except Exception:
        return False


def cmd_add(args, config_path):
    data = load_config(config_path)
    pkg = args.add.strip()

    if not is_installed_package(pkg):
        sys.exit(f"{RED}Error:{RESET} Package '{pkg}' is not installed on this system.")

    if is_aur_package(pkg):
        target_list = "aur_packages"
        list_name = "AUR packages (paru)"
    else:
        target_list = "system_packages"
        list_name = "System packages (pacman)"

    if pkg in data[target_list]:
        print(f"{YELLOW}Package '{pkg}' is already present in {list_name}.{RESET}")
        return

    data[target_list].append(pkg)
    save_config(config_path, data)
    print(f"{GREEN}✓ Added '{pkg}' to {list_name} in {config_path.name}{RESET}")


def cmd_remove(args, config_path):
    data = load_config(config_path)
    pkg = args.remove.strip()
    removed = False

    if pkg in data["system_packages"]:
        data["system_packages"].remove(pkg)
        removed = True
        print(f"{GREEN}✓ Removed '{pkg}' from system_packages.{RESET}")

    if pkg in data["aur_packages"]:
        data["aur_packages"].remove(pkg)
        removed = True
        print(f"{GREEN}✓ Removed '{pkg}' from aur_packages.{RESET}")

    if removed:
        save_config(config_path, data)
    else:
        print(f"{YELLOW}Package '{pkg}' was not found in Ansible configuration.{RESET}")


def main():
    parser = argparse.ArgumentParser(description="Synchronize Arch Linux packages with Ansible config.")
    parser.add_argument("--config", "-c", help="Path to group_vars/workstations.yml")
    parser.add_argument("--check", action="store_true", help="Check for drift without modifying config")
    parser.add_argument("--apply", "-a", action="store_true", help="Automatically update workstations.yml to match system")
    parser.add_argument("--interactive", "-i", action="store_true", help="Interactively select packages to add/remove")
    parser.add_argument("--add", help="Add a specific package to workstations.yml")
    parser.add_argument("--remove", help="Remove a specific package from workstations.yml")

    args = parser.parse_args()
    config_path = find_config_path(args.config)

    if args.add:
        cmd_add(args, config_path)
        return
    if args.remove:
        cmd_remove(args, config_path)
        return

    data = load_config(config_path)
    cfg_system = set(data.get("system_packages", []))
    cfg_aur = set(data.get("aur_packages", []))

    installed_native, installed_aur = get_installed_packages()

    uninstalled_system = cfg_system - installed_native
    uninstalled_aur = cfg_aur - installed_aur
    new_aur = installed_aur - cfg_aur
    new_native = installed_native - cfg_system

    print(f"{CYAN}{BOLD}=== Ansible Package Synchronization Audit ==={RESET}")
    print(f"Config File: {BOLD}{config_path}{RESET}\n")

    has_drift = False

    if uninstalled_system or uninstalled_aur:
        has_drift = True
        print(f"{RED}{BOLD}[Uninstalled Packages - Listed in Ansible but missing on System]{RESET}")
        for pkg in sorted(uninstalled_system):
            print(f"  {RED}- (pacman) {pkg}{RESET}")
        for pkg in sorted(uninstalled_aur):
            print(f"  {RED}- (aur)    {pkg}{RESET}")
        print()

    if new_aur:
        has_drift = True
        print(f"{GREEN}{BOLD}[New AUR Packages - Installed on System via paru but missing in Ansible]{RESET}")
        for pkg in sorted(new_aur):
            print(f"  {GREEN}+ (aur)    {pkg}{RESET}")
        print()

    if new_native:
        has_drift = True
        print(f"{YELLOW}{BOLD}[New System Packages - Installed on System via pacman but missing in Ansible: {len(new_native)}]{RESET}")
        sample = sorted(list(new_native))
        for pkg in sample[:15]:
            print(f"  {YELLOW}+ (pacman) {pkg}{RESET}")
        if len(sample) > 15:
            print(f"  {YELLOW}... and {len(sample) - 15} more packages{RESET}")
        print()

    if not has_drift:
        print(f"{GREEN}{BOLD}✓ Ansible package configuration is in perfect sync with your system!{RESET}")
        sys.exit(0)

    if args.check:
        print(f"{RED}Drift detected between system and Ansible config.{RESET}")
        sys.exit(1)

    if args.apply:
        print(f"{CYAN}Updating {config_path.name}...{RESET}")
        data["system_packages"] = sorted(list((cfg_system - uninstalled_system) | new_native))
        data["aur_packages"] = sorted(list((cfg_aur - uninstalled_aur) | new_aur))
        save_config(config_path, data)
        print(f"{GREEN}✓ Successfully updated {config_path.name}!{RESET}")
        return

    if args.interactive:
        modified = False
        if uninstalled_system or uninstalled_aur:
            print(f"{BOLD}Review uninstalled packages to REMOVE from Ansible config:{RESET}")
            for pkg in sorted(uninstalled_system):
                ans = input(f"Remove pacman package '{pkg}' from workstations.yml? [y/N]: ").strip().lower()
                if ans == 'y':
                    data["system_packages"].remove(pkg)
                    modified = True
            for pkg in sorted(uninstalled_aur):
                ans = input(f"Remove AUR package '{pkg}' from workstations.yml? [y/N]: ").strip().lower()
                if ans == 'y':
                    data["aur_packages"].remove(pkg)
                    modified = True

        if new_aur:
            print(f"\n{BOLD}Review new AUR packages to ADD to Ansible config:{RESET}")
            for pkg in sorted(new_aur):
                ans = input(f"Add AUR package '{pkg}' to workstations.yml? [Y/n]: ").strip().lower()
                if ans != 'n':
                    if pkg not in data["aur_packages"]:
                        data["aur_packages"].append(pkg)
                        modified = True

        if new_native:
            print(f"\n{BOLD}Review new System packages to ADD to Ansible config (Showing first 30):{RESET}")
            for pkg in sorted(list(new_native))[:30]:
                ans = input(f"Add system package '{pkg}' to workstations.yml? [y/N]: ").strip().lower()
                if ans == 'y':
                    if pkg not in data["system_packages"]:
                        data["system_packages"].append(pkg)
                        modified = True

        if modified:
            save_config(config_path, data)
            print(f"{GREEN}✓ Saved interactive changes to {config_path.name}{RESET}")
        else:
            print("No changes saved.")
        return

    print(f"To synchronize automatically, run: {BOLD}pkg-sync --apply{RESET}")
    print(f"To synchronize interactively, run: {BOLD}pkg-sync --interactive{RESET}")
    print(f"To add a specific package quickly, run: {BOLD}pkg-sync --add <pkg-name>{RESET}")


if __name__ == "__main__":
    main()
