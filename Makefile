OS := Debian
export
MAIN_PATH := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
OPERATING_SYSTEM := $(OS)

install: ## Install softwares and scripts.
	@cd installer && chmod 777 install.sh && ./install.sh 

link: ## Create & update symbolic link 
	@cd installer && chmod 777 link.sh && ./link.sh 

env: ## Setup developing environment
	@cd installer && chmod 777 env.sh && ./env.sh

unlink: ## Unlink symbolic link 
	@cd installer && chmod 777 unlink.sh && ./unlink.sh 

.DEFAULT_GOAL := help 
.PHONY: help install link env unlink 

help:  ## You can read help about this Makefile. 
	@echo "***rp-agota/dotfiles***" 
	@echo "You can install dotfiles for Debian/Arch. Don't forget write 'sudo'." 
	@echo "[e.g.] $ sudo make install OS=Debian" 
	@echo "" 
	@grep -E '^[0-9a-zA-Z_-]+[[:blank:]]*:.*?## .*$$' $(MAKEFILE_LIST) | sort \
	| awk 'BEGIN {FS = ":.*?## "}; {printf "\033[1;32m%-15s\033[0m %s\n", $$1, $$2}'
