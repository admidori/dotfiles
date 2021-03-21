#!/bin/bash

echo "----------[POWERLINE SHELL]----------"
git clone https://github.com/powerline/fonts.git --depth=1
cd fonts
./install.sh
cd ..
rm -rf fonts
gsettings set org.gnome.desktop.interface monospace-font-name 'Ubuntu Mono derivative Powerline 13'
pip install --user powerline-shell