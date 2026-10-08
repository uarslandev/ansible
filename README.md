# Dotfiles & Multi-OS Infrastructure Automation

A production-grade, multi-distribution automation repository designed to provision, bootstrap, and maintain development environments and dotfiles across **Arch Linux**, **WSL (Windows Subsystem for Linux)**, **Fedora VMs**, and **Ubuntu / Debian**.

---

## ⚡ Instant Setup (One-Command)

Run this single command in a terminal on **any fresh system** (Arch, WSL, Fedora VM, or Ubuntu):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/uarslandev/ansible/main/bin/dotfiles)"
```

### What this command does automatically:
1. **Detects the OS & Environment**: Identifies Arch Linux, WSL, Fedora, or Ubuntu/Debian.
2. **Bootstraps Prerequisites**: Automatically installs `ansible`, `git`, `python3`, and `chezmoi` via the native package manager (`pacman`, `dnf`, or `apt`).
3. **Clones Repository**: Clones this configuration repository to `~/.dotfiles`.
4. **Installs Galaxy Requirements**: Pulls required Ansible collections (`community.general`, `kubernetes.core`).
5. **Applies Dotfiles & Tools**: Executes [`main.yml`](file:///home/user/ansible/main.yml) on localhost to install developer packages and apply your dotfiles from [`uarslandev/dotfiles.git`](https://github.com/uarslandev/dotfiles.git).
6. **Exposes the `dotfiles` CLI**: Symlinks `dotfiles` to `~/.local/bin/dotfiles` so you can update and re-sync your environment anytime by simply running `dotfiles`.

---

## 📦 Alternative: Clone & Run

If you prefer to clone the repository manually before running:

```bash
# 1. Clone the repository
git clone https://github.com/uarslandev/ansible.git ~/.dotfiles
cd ~/.dotfiles

# 2. Run the bootstrap runner
./bin/dotfiles
```

---

## 💻 Supported Environments

| Environment | Supported Features | Package Manager | Desktop Services |
| :--- | :--- | :--- | :--- |
| **Arch Linux** (Bare-metal) | Pacman + Paru (AUR), Sway/Plasma, Ly DM, `pkgSync` | `pacman` + `paru` | Enabled |
| **WSL** (Windows Subsystem) | Fast CLI stack, Zsh, Neovim, Tmux, DevOps tools, Dotfiles | Native (`apt`/`dnf`/`pacman`) | Auto-skipped |
| **Fedora VM** / Host | Modern CLI dev stack, Chezmoi, Starship, Fastfetch, Dotfiles | `dnf` | Tailored |
| **Ubuntu / Debian** | Build-essential, CLI dev stack, Chezmoi, Starship, Dotfiles | `apt` | Tailored |

---

## 🏗️ Repository Structure

```
.
├── bin/
│   ├── dotfiles                 # Universal bootstrap CLI (supports curl | bash and local runs)
│   └── bootstrap -> dotfiles    # Symlink alias for bootstrapping
├── pre_tasks/                   # Multi-OS detection & normalization
│   ├── normalize_distribution.yml # Normalizes CachyOS/EndeavourOS -> Archlinux, Debian -> Ubuntu
│   ├── detect_wsl.yml           # Identifies WSL environment
│   ├── detect_session.yml       # Identifies desktop vs wsl vs headless/server session
│   ├── detect_sudo.yml          # Non-blocking privilege and package manager detection
│   ├── whoami.yml               # Resolves target non-root user and home directory
│   └── whoami_wsl.yml           # Resolves Windows host user in WSL
├── requirements/
│   └── common.yml               # Ansible Galaxy collections (community.general, kubernetes.core)
├── main.yml                     # Universal entrypoint (runs pre_tasks + dynamic roles on localhost)
├── ansible.cfg                  # Non-blocking configuration (become_ask_pass = False)
├── inventory.ini                # Inventory (localhost, workstations, wsl, vms, servers)
├── group_vars/
│   ├── all.yml                  # Global pipeline, role exclude filters, and Ubuntu/Fedora packages
│   ├── workstations.yml         # Arch Linux package definitions (pkgSync compatible)
│   └── servers.yml              # Server node variables
├── host_vars/
│   ├── pc.yml                   # Machine-specific packages (e.g. NVIDIA drivers)
│   └── thinkpad.yml             # Machine-specific packages (e.g. ZFS tools)
├── scripts/
│   ├── pkgSync                  # Arch Linux package synchronization utility
│   └── tmux-sessionizer         # Tmux session manager script
└── roles/
    ├── common/                  # Scaffolds ~/.local/bin, ~/.config, ~/.local/share
    ├── workstation/
    │   ├── tasks/main.yml       # Dispatches to distro tasks; guards desktop services
    │   ├── tasks/Archlinux.yml  # Pacman + paru + pkgSync (with WSL/VM hardware filtering)
    │   ├── tasks/Ubuntu.yml     # Apt packages + starship installer
    │   └── tasks/Fedora.yml     # Dnf packages (starship, fastfetch, chezmoi native)
    ├── devops_tools/            # Docker group & devops CLI tools (kubectl, helm, k9s, kind, terraform)
    └── dotfiles/                # Auto-installs chezmoi on any OS and applies dotfiles repo
```

---

## 📂 Managing Dotfiles Always from Here

Dotfiles are managed via **[Chezmoi](https://www.chezmoi.io/)** backed by [`https://github.com/uarslandev/dotfiles.git`](https://github.com/uarslandev/dotfiles.git).

### 1. Auto-apply Across All Systems
Running `dotfiles` or `ansible-playbook main.yml --tags dotfiles` ensures `chezmoi` is installed and runs `chezmoi apply --force` to synchronize:
- `~/.zshrc`
- `~/.tmux.conf`
- `~/.gitconfig`
- `~/.config/nvim/`
- `~/.config/sway/`
- `~/.config/waybar/`
- `~/.local/bin/tmux-sessionizer`

### 2. Modifying Dotfiles
To edit, test, and push dotfiles from any of your machines:

```bash
# 1. Edit a dotfile:
chezmoi edit ~/.zshrc
chezmoi edit ~/.config/nvim/init.lua

# 2. Inspect changes:
chezmoi diff

# 3. Commit and push to GitHub:
chezmoi cd
git commit -am "feat: update zsh config"
git push origin main
```

Running `dotfiles` on any other machine will immediately pull and apply those changes.

### 3. Adding New Config Files
```bash
chezmoi add ~/.config/new-app/config.yml
chezmoi cd
git add .
git commit -m "feat: track new-app config"
git push origin main
```

---

## 🎯 Selective Execution (Tags)

Run only specific parts of your configuration anytime:

```bash
# Sync dotfiles only:
dotfiles --tags dotfiles
# Or: ansible-playbook main.yml --tags dotfiles

# Run only DevOps tools setup:
dotfiles --tags devops
# Or: ansible-playbook main.yml --tags devops

# Run only base workstation packages:
dotfiles --tags workstation
# Or: ansible-playbook main.yml --tags workstation

# Run only directory scaffolding:
dotfiles --tags common
# Or: ansible-playbook main.yml --tags common
```

---

## 📦 Arch Linux Package Synchronization (`pkgSync`)

On Arch Linux workstations, two-way package synchronization between your installed system packages and Ansible is handled via `pkgSync`:

```bash
# Check package drift between system and workstations.yml:
pkgSync

# Update group_vars/workstations.yml to match installed system packages:
pkgSync --apply

# Interactively review package changes:
pkgSync --interactive

# Add or remove packages:
pkgSync --add spotify
pkgSync --remove foot
```
