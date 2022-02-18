#!/bin/bash

# Copyright (c) 2022 Midori Ado All Rights Reserved.
#      _           _        _ _       _
#     (_)_ __  ___| |_ __ _| | |  ___| |__
#     | | '_ \/ __| __/ _` | | | / __| '_ \
#     | | | | \__ \ || (_| | | |_\__ \ | | |
#     |_|_| |_|___/\__\__,_|_|_(_)___/_| |_|
# 

echo "#######################################"
echo "#         dotfiles ver.1.1            #"
echo "#           >>install.sh<<            #"
echo "#######################################"
echo "Copyright (c) 2022 Midori Ado All Rights Reserved."
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

echo "Install general softwere"

cd ~/dotfiles/bin/init
for f in *.sh
do
    sudo apt update
    chmod 777 $f
    ./$f
done

cd ~/dotfiles/bin
for f in *.sh
do
    sudo apt update
    chmod 777 $f
    ./$f
done

echo "#######################################"
echo "#         INSTALL COMPLETE            #"
echo "#######################################"
echo "Thank you for using dotfile."
echo "Good bye and Enjoy new computer!"
