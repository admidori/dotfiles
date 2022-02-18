#!/bin/bash
# Copyright (c) 2022 Midori Ado All Rights Reserved.
#    _ _       _          _     
#   | (_)_ __ | | __  ___| |__  
#   | | | '_ \| |/ / / __| '_ \ 
#   | | | | | |   < _\__ \ | | |
#   |_|_|_| |_|_|\_(_)___/_| |_|
#                            

for f in .??*
do
    [[ "$f" == ".git" ]] && continue
    [[ "$f" == ".gitignore" ]] && continue

    ln -sf ~/dotfiles/mac/$f ~/$f
    echo "$f linked!"
done

if [ "$(uname)" == 'Darwin' ]; then
    for f in .??*
    do
        [[ "$f" == ".git" ]] && continue
        [[ "$f" == ".gitignore" ]] && continue

        ln -sf ~/dotfiles/shared/$f ~/$f
        echo "$f linked!"
    done
    for f in .??*
    do
        [[ "$f" == ".git" ]] && continue
        [[ "$f" == ".gitignore" ]] && continue

        ln -sf ~/dotfiles/mac/$f ~/$f
        echo "$f linked!"
    done
elif [ "$(expr substr $(uname -s) 1 5)" == 'Linux' ]; then
    for f in .??*
    do
        [[ "$f" == ".git" ]] && continue
        [[ "$f" == ".gitignore" ]] && continue

        ln -sf ~/dotfiles/shared/$f ~/$f
        echo "$f linked!"
    done
    for f in .??*
    do
        [[ "$f" == ".git" ]] && continue
        [[ "$f" == ".gitignore" ]] && continue

        ln -sf ~/dotfiles/shared/Linux/$f ~/$f
        echo "$f linked!"
    done
    if [ OPERATING_SYSTEM == 'Debian' ]; then
        for f in .??*
        do
            [[ "$f" == ".git" ]] && continue
            [[ "$f" == ".gitignore" ]] && continue

            ln -sf ~/dotfiles/debian/$f ~/$f
            echo "$f linked!"
        done
    else
        for f in .??*
        do
            [[ "$f" == ".git" ]] && continue
            [[ "$f" == ".gitignore" ]] && continue

            ln -sf ~/dotfiles/arch/$f ~/$f
            echo "$f linked!"
        done
    fi
else
  echo "Your platform ($(uname -a)) is not supported."
  exit 1
fi