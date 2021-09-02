#!/bin/bash

for f in .??*
do
    #Write ignore files
    [[ "$f" == ".git" ]] && continue
    [[ "$f" == ".DS_Store" ]] && continue
    [[ "$f" == ".vscode" ]] && continue
    [[ "$f" == ".mc.menu" ]] && continue
    [[ "$f" == ".gitignore" ]] && continue
    [[ "$f" == ".gnuplot" ]] && continue

    ln -sf ~/dotfiles/$f ~/$f
    echo "$f linked!"
done