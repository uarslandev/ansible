# Infrastructure & Workstation Automation (Ansible Monorepo)

A production-grade Ansible monorepo designed to provision and maintain **Fedora Workstation**, laptops, and future servers with full reproducibility, following modern **DevOps paradigms**.

---

## 🏗️ Architecture

```
.
├── ansible.cfg              # Default Ansible runtime configuration
├── inventory.ini            # Infrastructure directory (localhost, workstations, servers)
├── site.yml                 # Master playbook orchestrating all roles
├── group_vars/              # Variables scoped by host groups
│   ├── all.yml              # Global settings (user home, dotfiles repo, bin path)
│   ├── workstations.yml     # Fedora Workstation packages, Flatpaks, tool versions
│   └── servers.yml          # Server node variables
└── roles/                   # Modular automation roles
    ├── common/              # Base setup (Flathub, Podman socket, ~/.local/bin)
    ├── workstation/         # Fedora DNF CLI tools & Flatpak GUI apps
    ├── devops_tools/        # Kubernetes (kubectl, helm, k9s, kind) & Terraform
    └── dotfiles/            # Chezmoi dotfiles initialization & directory scaffolding
```

---

## 🛠️ Included DevOps Stack

- **Containerization**: Podman (User-space socket enabled by default)
- **Kubernetes Ecosystem**: `kubectl`, `helm`, `k9s`, `kind` (Kubernetes in Podman/Docker)
- **Infrastructure as Code**: `terraform`
- **CLI Development**: `neovim`, `tmux`, `zsh`, `git`, `ripgrep`, `fzf`, `btop`, `fastfetch`
- **Dotfiles Engine**: `chezmoi`
- **Flatpak Apps**: Vesktop, Spotify, Obsidian

---

## 🚀 Quickstart Guide

### 1. Run Local Provisioning (Fedora Workstation)

Execute the master playbook against `localhost`:

```bash
ansible-playbook site.yml --ask-become-pass
```

> **Note:** `--ask-become-pass` prompts for your `sudo` password to perform DNF package installations cleanly.

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
