export
MAIN_PATH := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

install: ## Install softwares and scripts.
	@cd installer && chmod 777 install.sh && ./install.sh 

link: ## Create & update symbolic link 
	@cd installer && chmod 777 link.sh && ./link.sh 

unlink: ## Unlink symbolic link 
	@cd installer && chmod 777 unlink.sh && ./unlink.sh 

.DEFAULT_GOAL := help 
.PHONY: help install link env unlink 

help:  ## You can read help about this Makefile. 
	@echo "***admidori/dotfiles***" 
	@echo "You can install dotfiles for Ubuntu." 
	@echo "[e.g.] $ sudo make install" 
	@echo "" 
	@grep -E '^[0-9a-zA-Z_-]+[[:blank:]]*:.*?## .*$$' $(MAKEFILE_LIST) | sort \
	| awk 'BEGIN {FS = ":.*?## "}; {printf "\033[1;32m%-15s\033[0m %s\n", $$1, $$2}'
