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
  pkg-sync --host <hostname>        Include and update host_vars/<hostname>.yml
  pkg-sync --config <path>          Path to the shared workstation config
"""

import sys
import argparse
import subprocess
import pathlib
import socket
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

    # Candidate locations relative to script or current directory
    candidates = [
        pathlib.Path.cwd() / "group_vars" / "workstations.yml",
        pathlib.Path(__file__).resolve().parent.parent / "group_vars" / "workstations.yml",
        pathlib.Path.home() / "ansible" / "group_vars" / "workstations.yml",
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate.resolve()

    sys.exit(f"{RED}Error:{RESET} Could not locate group_vars/workstations.yml. Use --config to specify path.")


def find_host_config_path(shared_path, host=None):
    """Return the requested or current host's package manifest when available."""
    host_vars_dir = shared_path.parent.parent / "host_vars"

    if host:
        path = host_vars_dir / f"{host}.yml"
        if not path.exists():
            sys.exit(f"{RED}Error:{RESET} Host package config does not exist: {path}")
        return path.resolve()

    # `socket.gethostname()` is normally the same name used in inventory. Also
    # try its short form for systems whose hostname is fully qualified.
    hostname = socket.gethostname()
    candidates = [hostname]
    if "." in hostname:
        candidates.append(hostname.split(".", 1)[0])

    for candidate in candidates:
        path = host_vars_dir / f"{candidate}.yml"
        if path.exists():
            return path.resolve()

    return None


def load_config(config_path, host_config_path=None):
    with open(config_path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    data.setdefault("system_packages", [])
    data.setdefault("aur_packages", [])
    data.setdefault("devops_tool_versions", {})

    if host_config_path:
        with open(host_config_path, "r", encoding="utf-8") as f:
            host_data = yaml.safe_load(f) or {}
        data["system_packages"] = data["system_packages"] + host_data.get("host_system_packages", [])
        data["aur_packages"] = data["aur_packages"] + host_data.get("host_aur_packages", [])

    return data


def save_config(config_path, data, shared_config=None):
    system_packages = sorted(list(set(data.get("system_packages", []))))
    aur_packages = sorted(list(set(data.get("aur_packages", []))))
    devops_tool_versions = data.get("devops_tool_versions", {})

    if shared_config is not None:
        shared_system = set(shared_config.get("system_packages", []))
        shared_aur = set(shared_config.get("aur_packages", []))
        lines = [
            "---",
            "# Packages unique to this host; shared packages are in group_vars/workstations.yml.",
            "host_system_packages:",
        ]
        host_system_packages = sorted(set(system_packages) - shared_system)
        host_aur_packages = sorted(set(aur_packages) - shared_aur)
        if host_system_packages:
            for pkg in host_system_packages:
                lines.append(f"  - {pkg}")
        else:
            lines.append("  []")

        lines.append("")
        lines.append("host_aur_packages:")
        if host_aur_packages:
            for pkg in host_aur_packages:
                lines.append(f"  - {pkg}")
        else:
            lines.append("  []")
        lines.append("")

        with open(config_path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines))
        return

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
    # Helper to execute paru or pacman
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


def is_paru_companion_package(pkg):
    """Ignore paru split/debug packages; only the paru helper itself is managed."""
    return pkg.startswith("paru-")


def cmd_add(args, config_path, data, shared_config=None):
    pkg = args.add.strip()

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
    save_config(config_path, data, shared_config)
    print(f"{GREEN}✓ Added '{pkg}' to {list_name} in {config_path.name}{RESET}")


def cmd_remove(args, config_path, data, shared_config=None):
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
        save_config(config_path, data, shared_config)
    else:
        print(f"{YELLOW}Package '{pkg}' was not found in Ansible configuration.{RESET}")


def main():
    parser = argparse.ArgumentParser(description="Synchronize Arch Linux packages with Ansible config.")
    parser.add_argument("--config", "-c", help="Path to group_vars/workstations.yml")
    parser.add_argument(
        "--host",
        help="Hostname whose host_vars package file should be included and updated "
        "(defaults to the current host when its manifest exists)",
    )
    parser.add_argument("--check", action="store_true", help="Check for drift without modifying config")
    parser.add_argument("--apply", "-a", action="store_true", help="Automatically update workstations.yml to match system")
    parser.add_argument("--interactive", "-i", action="store_true", help="Interactively select packages to add/remove")
    parser.add_argument("--add", help="Add a specific package to workstations.yml")
    parser.add_argument("--remove", help="Remove a specific package from workstations.yml")

    args = parser.parse_args()
    shared_path = find_config_path(args.config)
    shared_config = None
    config_path = shared_path
    host_path = find_host_config_path(shared_path, args.host)
    if host_path:
        shared_config = load_config(shared_path)
        config_path = host_path

    data = load_config(shared_path, config_path if shared_config is not None else None)

    if args.add:
        cmd_add(args, config_path, data, shared_config)
        return
    if args.remove:
        cmd_remove(args, config_path, data, shared_config)
        return

    cfg_system = set(data.get("system_packages", []))
    cfg_aur = set(data.get("aur_packages", []))

    installed_native, installed_aur = get_installed_packages()

    # Calculate diff
    # 1. Packages listed in config but NOT installed on system (Removed from system)
    uninstalled_system = cfg_system - installed_native
    uninstalled_aur = cfg_aur - installed_aur

    # 2. Packages installed on system but NOT listed in config (Newly installed)
    # Note: Only list explicit AUR pkgs or explicit native pkgs
    # paru-debug and other paru split packages are build companions, not
    # independently managed AUR packages. Keep only the main `paru` package.
    new_aur = {
        pkg for pkg in (installed_aur - cfg_aur)
        if not is_paru_companion_package(pkg)
    }

    # Print summary
    print(f"{CYAN}{BOLD}=== Ansible Package Synchronization Audit ==={RESET}")
    if shared_config is not None:
        print(f"Shared Config: {BOLD}{shared_path}{RESET}")
        print(f"Host Config:   {BOLD}{config_path}{RESET}\n")
    else:
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

    # Check for newly installed native packages that might be worth tracking
    new_native = installed_native - cfg_system
    if new_native:
        print(f"{YELLOW}{BOLD}[Explicitly Installed Pacman Packages not in Ansible config: {len(new_native)}]{RESET}")
        # Display first 15 as sample if many
        sample = sorted(list(new_native))
        for pkg in sample[:15]:
            print(f"  {YELLOW}+ (pacman) {pkg}{RESET}")
        if len(sample) > 15:
            print(f"  {YELLOW}... and {len(sample) - 15} more packages{RESET}")
        print()

    if not has_drift and not new_native:
        print(f"{GREEN}{BOLD}✓ Ansible package configuration is in perfect sync with your system!{RESET}")
        sys.exit(0)

    if args.check:
        if has_drift:
            print(f"{RED}Drift detected between system and Ansible config.{RESET}")
            sys.exit(1)
        sys.exit(0)

    if args.apply:
        print(f"{CYAN}Updating {config_path.name}...{RESET}")
        # Remove uninstalled packages from config
        data["system_packages"] = sorted(list(cfg_system - uninstalled_system))
        data["aur_packages"] = sorted(list((cfg_aur - uninstalled_aur) | new_aur))
        save_config(config_path, data, shared_config)
        print(f"{GREEN}✓ Successfully updated {config_path.name}!{RESET}")
        if uninstalled_system or uninstalled_aur:
            print(f"  - Removed {len(uninstalled_system) + len(uninstalled_aur)} uninstalled packages.")
        if new_aur:
            print(f"  + Added {len(new_aur)} new AUR packages.")
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

        if modified:
            save_config(config_path, data, shared_config)
            print(f"{GREEN}✓ Saved interactive changes to {config_path.name}{RESET}")
        else:
            print("No changes saved.")
        return

    print(f"To synchronize automatically, run: {BOLD}pkg-sync --apply{RESET}")
    print(f"To synchronize interactively, run: {BOLD}pkg-sync --interactive{RESET}")


if __name__ == "__main__":
    main()
