# Infrastructure & Workstation Automation (Ansible Monorepo)

A production-grade Ansible monorepo designed to provision and maintain **minimal Arch Linux and WSL developer environments** with full reproducibility, following modern **DevOps paradigms**.

---

## 🏗️ Architecture

```
.
├── ansible.cfg              # Default Ansible runtime configuration
├── inventory.ini            # Infrastructure directory (localhost, workstations, servers)
├── site.yml                 # Master playbook orchestrating all roles
├── group_vars/              # Variables scoped by host groups
│   ├── all.yml              # Global settings (user home, dotfiles repo, bin path)
│   ├── workstations.yml     # Minimal Arch package set and tool versions
│   └── servers.yml          # Server node variables
└── roles/                   # Modular automation roles
    ├── common/              # Base setup (~/.local/bin)
    ├── workstation/         # Arch pacman CLI tools, sway/ly desktop, and paru bootstrap
    ├── devops_tools/        # Kubernetes (kubectl, helm, k9s, kind) & Terraform
    └── dotfiles/            # Chezmoi dotfiles initialization & directory scaffolding
```

---

## 🛠️ Included DevOps Stack

- **Desktop Session**: `ly` display manager + `sway` Wayland compositor + `i3status`
- **Kubernetes Ecosystem**: `kubectl`, `helm`, `k9s`, `kind`
- **Infrastructure as Code**: `terraform`
- **CLI Development**: `neovim`, `tmux`, `zsh`, `git`, `ripgrep`, `fzf`, `btop`, `fastfetch`
- **Dotfiles Engine**: `chezmoi`
- **AUR Helper**: `paru`

---

## 🚀 Quickstart Guide

### 1. Run Local Provisioning (Arch Linux / WSL)

Execute the master playbook against `localhost`:

```bash
ansible-playbook site.yml --ask-become-pass
```

> **Note:** `--ask-become-pass` prompts for your `sudo` password to perform pacman package installations cleanly.

### 2. Selective Execution (Tags / Limit)

Run only the DevOps CLI tools setup (no sudo needed):

```bash
ansible-playbook site.yml --tags devops
```

Target only local workstation tasks:

```bash
ansible-playbook -i inventory.ini site.yml --limit workstations --ask-become-pass
```

---

## 📂 Dotfiles Management with Chezmoi

1. **Track a configuration file:**
   ```bash
   chezmoi add ~/.config/nvim
   chezmoi add ~/.tmux.conf
   chezmoi add ~/.zshrc
   ```

2. **Commit and sync dotfiles:**
   ```bash
   chezmoi cd
   git remote add origin git@github.com:YOUR_USERNAME/dotfiles.git
   git push -u origin main
   ```

3. **Auto-apply on fresh machine:**
   Update `dotfiles_repo` in `group_vars/all.yml` with your repository URL. Running `ansible-playbook site.yml` will automatically initialize and apply your dotfiles!

---

## 📦 Package Management & Synchronization (`pkg-sync`)

This setup features two-way package synchronization between Arch Linux and Ansible:

1. **Ansible -> System (Playbook Execution)**:
   - Running `ansible-playbook site.yml` installs all packages in `group_vars/workstations.yml`.
   - Any package removed from `system_packages` or `aur_packages` is automatically uninstalled from Arch Linux.
   - `paru` is automatically bootstrapped if not present on the system.

2. **System -> Ansible (`pkg-sync` CLI Tool)**:
   - When you install packages manually using `paru -S <pkg>` or remove packages via `paru -R <pkg>`, use `pkg-sync` to keep `group_vars/workstations.yml` updated.

   ```bash
   # Check package drift between system and workstations.yml
   pkg-sync

   # Automatically update workstations.yml to match your installed packages
   pkg-sync --apply

   # Interactively review and update package lists
   pkg-sync --interactive

   # Explicitly add or remove a package (auto-detects pacman vs AUR)
   pkg-sync --add spotify
   pkg-sync --remove foot
   ```

3. **Playbook Package Audit**:
   ```bash
   ansible-playbook sync.yml
   ```

---

## 🖥️ Expanding to Home Server / Remote Nodes

To manage remote Linux servers or laptops:

1. Add target IPs into `inventory.ini` under `[servers]`:
   ```ini
   [servers]
   homeserver.local ansible_host=192.168.1.100 ansible_user=root
   ```
2. Run the playbook against the server target:
   ```bash
   ansible-playbook site.yml --limit servers
   ```

