OS := Debian
PATH := $(cd $(dirname $0);pwd)

install: export OPERATING_SYSTEM := $(OS)
install: export MAIN_PATH := $(PATH)
install: ## Install softwares and scripts.
	@cd installer && chmod 777 install.sh && ./install.sh 

link: export OPERATING_SYSTEM := $(OS)
link: export MAIN_PATH := $(PATH)
link: ## Create & update symbolic link 
	@cd installer && chmod 777 link.sh && ./link.sh 
  
unlink: ## Unlink symbolic link 
	@cd installer && chmod 777 unlink.sh && ./unlink.sh 
  
.DEFAULT_GOAL := help 
.PHONY: help install link unlink 
  
help:  ## You can read help about this Makefile. 
	@echo "***rp-agota/dotfiles***" 
	@echo "You can install dotfiles for Debian/Arch. Don't forget write 'sudo'." 
	@echo "[e.g.] $ sudo make install OS=Debian" 
	@echo "" 
	@grep -E '^[0-9a-zA-Z_-]+[[:blank:]]*:.*?## .*$$' $(MAKEFILE_LIST) | sort \
	| awk 'BEGIN {FS = ":.*?## "}; {printf "\033[1;32m%-15s\033[0m %s\n", $$1, $$2}'
