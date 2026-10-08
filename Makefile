# ==============================================================================
# Developer Makefile - Automation Shortcuts
# ==============================================================================

.DEFAULT_GOAL := help
.PHONY: help apply dotfiles check lint sync test

help:
	@echo "Infrastructure & Dotfiles Automation"
	@echo ""
	@echo "Usage:"
	@echo "  make apply      Run full setup across current OS"
	@echo "  make dotfiles   Fast sync: apply dotfiles only via Chezmoi"
	@echo "  make check      Perform a dry-run check without applying changes"
	@echo "  make lint       Verify playbook syntax and run ansible-lint"
	@echo "  make sync       Audit package drift via pkgSync (Arch Linux)"

apply:
	./bin/dotfiles

dotfiles:
	./bin/dotfiles --tags dotfiles

check:
	ansible-playbook main.yml --check

lint:
	ansible-playbook main.yml --syntax-check
	ansible-lint main.yml

sync:
	ansible-playbook sync.yml
