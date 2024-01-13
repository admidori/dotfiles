#!/bin/sh

# Copyright (c) 2021-2024 Aoi Kondo All Rights Reserved.
#      _           _        _ _       _
#     (_)_ __  ___| |_ __ _| | |  ___| |__
#     | | '_ \/ __| __/ _` | | | / __| '_ \
#     | | | | \__ \ || (_| | | |_\__ \ | | |
#     |_|_| |_|___/\__\__,_|_|_(_)___/_| |_|
# 

echo ""
echo "#######################################"
echo "#         dotfiles 2024-v1            #"
echo "#          >>install.sh<<             #"
echo "#######################################"
echo "Copyright (c) 2021-2024 Aoi Kondo All Rights Reserved."
echo ""
echo "Hello! Welcome to install.sh!"
echo ""

echo "########################"
echo "#  MAKE SYMBOLIC LINK  #"
echo "########################"
echo "Make Symbolic link from dotfiles."
cd $MAIN_PATH/installer
chmod 777 link.sh
./link.sh
echo "Link Successful."

echo ""
echo "########################"
echo "#   INSTALL SOFTWARES  #"
echo "########################"
echo "Install general softwere"
cd $MAIN_PATH/bin/arch
for f in ??*.sh
do
    chmod 777 $f
    ./$f
    echo "installed $f"
done

echo "#######################################"
echo "#         INSTALL COMPLETE            #"
echo "#######################################"
echo "Enjoy your new computer!"
exit
