export
MAIN_PATH := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

install: ## Install software, oh-my-zsh, and symlinks.
	@cd installer && chmod +x install.sh && ./install.sh

link: ## Create & update symbolic links.
	@cd installer && chmod +x link.sh && ./link.sh

unlink: ## Remove symbolic links created by this repo.
	@cd installer && chmod +x unlink.sh && ./unlink.sh

.DEFAULT_GOAL := help
.PHONY: help install link unlink

help:  ## You can read help about this Makefile.
	@echo "***admidori/dotfiles***"
	@echo "You can install dotfiles for Debian/Ubuntu."
	@echo "[e.g.] $$ make install"
	@echo ""
	@grep -E '^[0-9a-zA-Z_-]+[[:blank:]]*:.*?## .*$$' $(MAKEFILE_LIST) | sort \
	| awk 'BEGIN {FS = ":.*?## "}; {printf "\033[1;32m%-15s\033[0m %s\n", $$1, $$2}'
