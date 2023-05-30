#!/bin/sh

# Copyright (c) 2021-2023 Aoi Kondo All Rights Reserved.
#      _           _        _ _       _
#     (_)_ __  ___| |_ __ _| | |  ___| |__
#     | | '_ \/ __| __/ _` | | | / __| '_ \
#     | | | | \__ \ || (_| | | |_\__ \ | | |
#     |_|_| |_|___/\__\__,_|_|_(_)___/_| |_|
# 

echo ""
echo "#######################################"
echo "#         dotfiles ver 3.1            #"
echo "#          >>install.sh<<             #"
echo "#######################################"
echo "Copyright (c) 2021-2023 Aoi Kondo All Rights Reserved."
echo ""
echo "Hello! Welcome to install.sh!"
echo ""

echo "########################"
echo "#  MAKE SYMBOLIC LINK  #"
echo "########################"
echo "Make Symbolic link from dotfiles!"
cd $MAIN_PATH/installer/ubuntu
chmod 777 link.sh
./link.sh
echo "Link succeeded!"

echo ""
echo "########################"
echo "#   INSTALL SOFTWARES  #"
echo "########################"
echo "Install general softwere"
cd $MAIN_PATH/bin/dotfiles
for f in ??*.sh
do
    chmod 777 $f
    ./$f
    echo "$f Downloaded!"
done

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
