#!/bin/sh

# Copyright (c) 2021-2022 Midori Ado All Rights Reserved.
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
echo "Copyright (c) 2021-2022 Midori Ado All Rights Reserved."
echo ""
echo "Hello! Welcome to install.sh!"
echo ""

if [[ $OPERATING_SYSTEM = "Debian" ]]; then
				echo "Starting to install dotfile for Debian..."
        echo "########################"
        echo "#  MAKE SYMBOLIC LINK  #"
        echo "########################"
        echo "Make Symbolic link from dotfiles!"
				cd $MAIN_PATH/installer
        chmod 777 link.sh
        ./link.sh
        echo "Link succeeded!"
        echo ""
        echo "########################"
        echo "#   INSTALL SOFTWARES  #"
        echo "########################"
        echo "Install general softwere"

        cd $MAIN_PATH/debian/bin/init
        for f in *.sh
        do
            sudo apt update
            chmod 777 $f
            ./$f
        done

        cd $MAIN_PATH/debian/bin/tools
        for f in *.sh
        do
            sudo apt update
            chmod 777 $f
            ./$f
        done

        cd $MAIN_PATH/debian/bin/final
        for f in *.sh
        do
            sudo apt update
            chmod 777 $f
            ./$f
        done
    
        cd $MAIN_PATH/debian/etc
        for f in *.sh
        do
            sudo apt update
            chmod 777 $f
            ./$f
        done

elif [[ $OPERATING_SYSTEM = "Arch" ]]; then
				echo "Starting to install dotfile for Arch..."
        echo "########################"
        echo "#   MAKE SYMBOLIC LINK #"
        echo "########################"
        echo "Make Symbolic link from dotfiles!"
        cd $MAIN_PATH/installer
				chmod 777 link.sh
        ./link.sh
        echo "Link succeeded!"
        echo ""
        echo "########################"
        echo "#    INSTALL SOFTWARES #"
        echo "########################"
        echo "Install fonts"
        cd $MAIN_PATH/arch/bin/fonts
        for f in *.sh
        do
            chmod 777 $f
            ./$f
        done

        echo "Install general softwere"
        cd $MAIN_PATH/arch/bin/general
        for f in *.sh
        do
            chmod 777 $f
            ./$f
        done

        echo "Install tools"
        cd $MAIN_PATH/arch/bin/tools
        for f in *.sh
        do
            chmod 777 $f
            ./$f
        done

        echo "Install etc program"
        cd $MAIN_PATH/arch/etc
        for f in *.sh
        do
            chmod 777 $f
            ./$f
        done
        echo "########################"
        echo "# SETUP WINDOW MANAGER #"
        echo "########################"
        echo "Window-Manager i3 setup"
        cd $MAIN_PATH/arch/i3/
        chmod 777 install.sh
        ./install.sh
fi

cd $MAIN_PATH/installer
chmod 777 env.sh
./env.sh

echo "########################"
echo "#      SETUP ZSH       #"
echo "########################"
curl -sL --proto-redir -all,https https://raw.githubusercontent.com/zplug/installer/master/installer.zsh|
zsh
chsh -s $(which zsh)

echo "#######################################"
echo "#         INSTALL COMPLETE            #"
echo "#######################################"
echo "Thank you for using dotfile."
echo "Good bye and enjoy new computer!"
exit
