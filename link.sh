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
        [[ "$f" == ".github" ]] && continue

        ln -sf ~/dotfiles/$f ~/$f
        echo "$f linked!"
    done

if [ $OPERATING_SYSTEM == 'Debian' ]; then
    cd ~/dotfiles/shared
    for f in .??*
    do
        [[ "$f" == ".gitignore" ]] && continue

        ln -sf ~/dotfiles/shared/$f ~/$f
        echo "$f linked!"
    done
    cd ~/dotfiles/shared/Linux
    for f in .??*
    do
        [[ "$f" == ".gitignore" ]] && continue

        ln -sf ~/dotfiles/shared/Linux/$f ~/$f
        echo "$f linked!"
    done
elif [ $OPERATING_SYSTEM == 'Arch' ]; then
	      cd ~/dotfiles/arch
        for f in .??*
        do
            [[ "$f" == ".gitignore" ]] && continue
            
						ln -sf ~/dotfiles/arch/$f ~/$f
            echo "$f linked!"
        done
else
  echo "Your platform ($(uname -a)) is not supported."
  exit 1
fi
