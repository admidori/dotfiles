#!/bin/bash

# Copyright (c) 2022 Midori Ado All Rights Reserved.
#      _           _        _ _       _
#     (_)_ __  ___| |_ __ _| | |  ___| |__
#     | | '_ \/ __| __/ _` | | | / __| '_ \
#     | | | | \__ \ || (_| | | |_\__ \ | | |
#     |_|_| |_|___/\__\__,_|_|_(_)___/_| |_|
# 

echo "#######################################"
echo "#         dotfiles ver 2.0            #"
echo "#          >>install.sh<<             #"
echo "#######################################"
echo "Copyright (c) 2022 Midori Ado All Rights Reserved."
echo ""
echo "Hello! Welcome to install.sh!"
echo ""

if [ "$(uname)" == 'Darwin' ]; then
    export OPERATING_SYSTEM="Mac"
elif [ "$(expr substr $(uname -s) 1 5)" == 'Linux' ]; then
    echo -n "Which is your Linux distribution?"
    echo -n "Debian -> 1"
    echo -n "Arch Linux -> 2"
    read str
    if [ str="1" ]; then
        export OPERATING_SYSTEM="Debian"
        echo "########################"
        echo "#      FIRST STEP      #"
        echo "########################"
        echo "Make Symbolic link from dotfiles!"
        chmod 777 link.sh
        ./link.sh
        echo "Link succeeded!"
        echo ""
        echo "########################"
        echo "#      SECOND STEP     #"
        echo "########################"
        echo "Install general softwere"

        cd ~/dotfiles/debian/bin/init
        for f in *.sh
        do
            sudo apt update
            chmod 777 $f
            ./$f
        done

        cd ~/dotfiles/debian/bin
        for f in *.sh
        do
            sudo apt update
            chmod 777 $f
            ./$f
        done

        cd ~/dotfiles/debian/bin/final
        for f in *.sh
        do
            sudo apt update
            chmod 777 $f
            ./$f
        done
    
    elif [ str="2" ]; then
        export OPERATING_SYSTEM="Arch"
        echo "########################"
        echo "#      FIRST STEP      #"
        echo "########################"
        echo "Make Symbolic link from dotfiles!"
        chmod 777 link.sh
        ./link.sh
        echo "Link succeeded!"
        echo ""
        echo "########################"
        echo "#      SECOND STEP     #"
        echo "########################"
        echo "Install fonts"
        cd ~/dotfiles/arch/bin/fonts
        for f in *.sh
        do
            chmod 777 $f
            ./$f
        done

        echo "Install general softwere"
        cd ~/dotfiles/arch/bin/general
        for f in *.sh
        do
            chmod 777 $f
            ./$f
        done

        echo "Install tools"
        cd ~/dotfiles/arch/bin/tools
        for f in *.sh
        do
            chmod 777 $f
            ./$f
        done

        echo "Install etc program"
        cd ~/dotfiles/arch/etc
        for f in *.sh
        do
            chmod 777 $f
            ./$f
        done
        echo "########################"
        echo "#      THIRD STEP      #"
        echo "########################"
        echo "Window-Manager i3 setup"
        cd ~/dotfiles/arch/i3/
        chmod 777 install.sh
        ./install.sh
    fi
        
else
  echo "Your platform ($(uname -a)) is not supported."
  exit 1
fi

echo "#######################################"
echo "#         INSTALL COMPLETE            #"
echo "#######################################"
echo "Thank you for using dotfile."
echo "Good bye and enjoy new computer!"
