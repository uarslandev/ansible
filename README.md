# Infrastructure & Workstation Automation (Ansible Monorepo)

A production-grade Ansible monorepo designed to provision and maintain **minimal Arch Linux and WSL developer environments** with full reproducibility, following modern **DevOps paradigms**.

---

## 🏗️ Architecture

```
.
├── ansible.cfg              # Default Ansible runtime configuration
├── inventory.ini            # Infrastructure directory (localhost, workstations, servers)
├── site.yml                 # Master playbook orchestrating all roles
├── workstation.yml          # Shared workstation playbook imported by each host
├── pc.yml                   # Entry point for the local pc workstation
├── group_vars/              # Variables scoped by host groups
│   ├── all.yml              # Global settings (user home, dotfiles repo, bin path)
│   ├── workstations.yml     # Minimal Arch package set and tool versions
│   └── servers.yml          # Server node variables
├── host_vars/               # Machine-specific variables
│   └── pc.yml               # Packages unique to pc
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

Execute the host-specific playbook:

```bash
ansible-playbook pc.yml --ask-become-pass
```

> **Note:** `--ask-become-pass` prompts for your `sudo` password to perform pacman package installations cleanly.

### 2. Selective Execution (Tags / Limit)

Run only the DevOps CLI tools setup (no sudo needed):

```bash
ansible-playbook site.yml --tags devops
```

Run the shared configuration for every workstation:

```bash
ansible-playbook -i inventory.ini site.yml --limit workstations --ask-become-pass
```

### Add another workstation

1. Add its hostname to `[workstations]` in `inventory.ini`.
2. Create `host_vars/<hostname>.yml` with `host_system_packages` and/or
   `host_aur_packages`. These are added to the shared lists in
   `group_vars/workstations.yml`.
3. Create `<hostname>.yml` containing the same `import_playbook: workstation.yml`
   pattern as `pc.yml`, with `target_hosts` set to the hostname.
4. Run `ansible-playbook <hostname>.yml --ask-become-pass`.

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
   - Running `ansible-playbook pc.yml` installs the shared packages in `group_vars/workstations.yml` plus packages in `host_vars/pc.yml`.
   - Any package removed from `system_packages` or `aur_packages` is automatically uninstalled from Arch Linux.
   - `paru` is automatically bootstrapped if not present on the system.

2. **System -> Ansible (`pkg-sync` CLI Tool)**:
   - When you install packages manually using `paru -S <pkg>` or remove packages via `paru -R <pkg>`, use `pkg-sync --host pc` to keep the combined shared and pc-specific package manifests updated. New packages are saved to `host_vars/pc.yml`.

   ```bash
   # Check package drift for pc
   pkg-sync --host pc

   # Automatically update workstations.yml to match your installed packages
   pkg-sync --host pc --apply

   # Interactively review and update package lists
   pkg-sync --host pc --interactive

   # Explicitly add or remove a package (auto-detects pacman vs AUR)
   pkg-sync --host pc --add spotify
   pkg-sync --host pc --remove foot
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
