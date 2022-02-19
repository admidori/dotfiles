debian-install: ## Begin to run installer for Debian GNU/Linux 
	export OPERATING_SYSTEM := Debian 
	@chmod 777 install.sh && ./install.sh 
  
arch-install: ## Begin to run installer for Arch Linux 
	export OPERATING_SYSTEM := Arch 
	@chmod 777 install.sh && ./install.sh 
  
debian-link: ## Create & update symbolic link 
	export OPERATING_SYSTEM := Debian 
	@chmod 777 link.sh && ./link.sh 
  
arch-link: ## Create & update symbolic link 
	export OPERATING_SYSTEM := Arch 
	@chmod 777 link.sh && ./link.sh 
  
uninstall: ## Unlink symbolic link 
	@chmod 777 unlink.sh && ./unlink.sh 
  
.DEFAULT_GOAL := help 
.PHONY: help debian-install arch-install debian-link arch-link uninstall 
  
help:  ## You can read help about this Makefile. 
	@echo "***rp-agota/dotfiles***" 
	@echo "You can install dotfiles for Debian/Arch. Don't forget write 'sudo'." 
	@echo "[e.g.] $ sudo make debian-install" 
	@echo "" 
	@grep -E '^[0-9a-zA-Z_-]+[[:blank:]]*:.*?## .*$$' $(MAKEFILE_LIST) | sort \
	| awk 'BEGIN {FS = ":.*?## "}; {printf "\033[1;32m%-15s\033[0m %s\n", $$1, $$2}'
