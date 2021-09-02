#Enviromental valiables
DOTFILES_EXCLUDES := .DS_Store .git .gitignore
DOTFILES_TARGET   := $(wildcard .??*) bin
DOTFILES_DIR      := $(PWD)
DOTFILES_FILES    := $(filter-out $(DOTFILES_EXCLUDES), $(DOTFILES_TARGET))
.DEFAULT_GOAL := setup

#FULL-SETUP
.PHONY: fullsetup
fullsetup: deploy; init env ## Full setup.
#SET-UP
.PHONY: setup
setup: deploy; init ## setup.
#INIT
.PHONY: init
init: apt; initialize terminal ## Install tools ignore environment.
#DEPLOY
.PHONY: deploy
deploy: ## Move dotfiles to home directory.
	@$(foreach val, $(DOTFILES_FILES), ln -sfnv $(abspath $(val)) $(HOME)/$(val);)
#ENVIROMENT
.PHONY: env ## Setup environment for develop.
env: apt; environment


#INIT
apt:
	@$(bash ./etc/apt.sh)
initialize:
	@$(foreach val, $(wildcard ./etc/init/*.sh), bash $(val);)
terminal: zsh; zplug
zsh:
	@$(bash ./etc/terminal/zsh-install.sh)
zplug:
	@$(zsh ./etc/terminal/zplug-install.sh)

#ENVIROMENT
environment:
	@$(foreach val, $(wildcard ./etc/env/*.sh), bash $(val);)