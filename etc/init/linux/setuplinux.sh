#!/bin/bash

echo "change zsh!"
sudo apt update
sudo apt-get install -y zsh
chsh -s $(which zsh)

for f in .??*
do
    [[ "$f" == ".git" ]] && continue
    [[ "$f" == ".DS_Store" ]] && continue
    [[ "$f" == ".vscode" ]] && continue
    [[ "$f" == ".mc.menu" ]] && continue
    [[ "$f" == ".gitignore" ]] && continue

    ln -sf ~/dotfiles/etc/init/linux/$f ~/$f
    echo "$f linked!"
done