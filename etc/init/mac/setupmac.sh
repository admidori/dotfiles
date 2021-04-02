#!/bin/bash

echo "change zsh!"
chsh -s /bin/zsh

for f in .??*
do
    [[ "$f" == ".git" ]] && continue
    [[ "$f" == ".DS_Store" ]] && continue
    [[ "$f" == ".vscode" ]] && continue
    [[ "$f" == ".mc.menu" ]] && continue
    [[ "$f" == ".gitignore" ]] && continue

    ln -sf ~/dotfiles/etc/init/mac/$f ~/$f
    echo "$f linked!"
done