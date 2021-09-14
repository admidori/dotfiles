#!/bin/bash

# Copyright (c) 2021 Midori Ado All Rights Reserved.
#      _           _        _ _       _
#     (_)_ __  ___| |_ __ _| | |  ___| |__
#     | | '_ \/ __| __/ _` | | | / __| '_ \
#     | | | | \__ \ || (_| | | |_\__ \ | | |
#     |_|_| |_|___/\__\__,_|_|_(_)___/_| |_|
# 

echo "#######################################"
echo "#         dotfiles ver.1.0            #"
echo "#           >>install.sh<<            #"
echo "#######################################"
echo "Copyright (c) 2021 Midori Ado All Rights Reserved."
echo ""
echo "Hello! Welcome to install.sh!"

echo "########################"
echo "#      FIRST STEP      #"
echo "########################"
echo "Make Symbolic link from dotfiles!"
chmod 777 link.sh
./link.sh


echo "########################"
echo "#      SECOND STEP     #"
echo "########################"
echo "Install all softwere and tools"

echo "Install fonts"
cd ~/dotfiles/bin/fonts
for f in *.sh
do
    chmod 777 $f
    ./$f
done

echo "Install general softwere"
cd ~/dotfiles/bin/general
for f in *.sh
do
    chmod 777 $f
    ./$f
done

echo "Install tools"
cd ~/dotfiles/bin/tools
for f in *.sh
do
    chmod 777 $f
    ./$f
done

echo "----------[INSTALL ENDED!]----------"
echo "Thank you for using this install script."
echo "Good bye and Enjoy new computer!"
