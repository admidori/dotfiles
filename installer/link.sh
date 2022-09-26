#!/bin/bash
# Copyright (c) 2022 Midori Ado All Rights Reserved.
#    _ _       _          _     
#   | (_)_ __ | | __  ___| |__  
#   | | | '_ \| |/ / / __| '_ \ 
#   | | | | | |   < _\__ \ | | |
#   |_|_|_| |_|_|\_(_)___/_| |_|
#                            


echo "########################"
echo "#  MAKE SYMBOLIC LINK  #"
echo "########################"
if [ $OPERATING_SYSTEM == 'Debian' ]; then
    cd $MAIN_PATH/shared
    for f in .??*
    do
        [[ "$f" == ".gitignore" ]] && continue

        ln -sf $MAIN_PATH/shared/$f ~/$f
        echo "$f linked!"
    done
elif [ $OPERATING_SYSTEM == 'Arch' ]; then
	      cd $MAIN_PATH/arch
        for f in .??*
        do
            [[ "$f" == ".gitignore" ]] && continue
            
						ln -sf $MAIN_PATH/arch/$f ~/$f
            echo "$f linked!"
        done
else
  echo "Your platform ($(uname -a)) is not supported."
  exit 1
fi
