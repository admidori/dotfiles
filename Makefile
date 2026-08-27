export
MAIN_PATH := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
TEST_IMAGE := dotfiles-test

install: ## Install software, oh-my-zsh, and symlinks.
	@cd installer && chmod +x install.sh && ./install.sh

link: ## Create & update symbolic links.
	@cd installer && chmod +x link.sh && ./link.sh

link-ai: ## Create & update AI tool symbolic links only.
	@cd installer && chmod +x link-ai.sh && ./link-ai.sh

unlink: ## Remove symbolic links created by this repo.
	@cd installer && chmod +x unlink.sh && ./unlink.sh

# `docker run -t` allocates a pty. The suite ends by checking that an
# interactive zsh loads cleanly, and a real interactive shell has a terminal.
# Without one, anything touching zle warns (fzf's key bindings save and
# restore every shell option, and zle is settable only at startup with a
# terminal attached), and .zshrc's tty-gated branches take the path no
# interactive user ever hits.
test: ## Run the installer in a clean Debian container (needs Docker).
	docker build -t $(TEST_IMAGE) -f Dockerfile .
	docker run --rm -t $(TEST_IMAGE)

.DEFAULT_GOAL := help
.PHONY: help install link link-ai unlink test

help:  ## You can read help about this Makefile.
	@echo "***admidori/dotfiles***"
	@echo "You can install dotfiles for Debian/Ubuntu."
	@echo "On macOS, use \`make link-ai\` to link only AI tool configs."
	@echo "[e.g.] $$ make install"
	@echo ""
	@grep -E '^[0-9a-zA-Z_-]+[[:blank:]]*:.*?## .*$$' $(MAKEFILE_LIST) | sort \
	| awk 'BEGIN {FS = ":.*?## "}; {printf "\033[1;32m%-15s\033[0m %s\n", $$1, $$2}'
