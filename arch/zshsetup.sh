#!/bin/bash
#
#              _              _                    _
#      _______| |__  ___  ___| |_ _   _ _ __   ___| |__
#     |_  / __| '_ \/ __|/ _ \ __| | | | '_ \ / __| '_ \
#      / /\__ \ | | \__ \  __/ |_| |_| | |_) |\__ \ | | |
#     /___|___/_| |_|___/\___|\__|\__,_| .__(_)___/_| |_|
#                                      |_|
# 


sudo pacman -Syu --noconfirm xsel
sudo pacman -Syu --noconfirm zsh
curl -sL --proto-redir -all,https https://raw.githubusercontent.com/zplug/installer/master/installer.zsh| zsh
chsh -s $(which zsh)
exit