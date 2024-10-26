#!/bin/sh

sudo apt update
sudo apt install -y ninja-build gettext cmake unzip curl build-essential
git clone -b stable --depth=1 https://github.com/neovim/neovim.git ../tmp/neovim
cd ../tmp/neovim
git checkout stable
make CMAKE_BUILD_TYPE=Release -j
sudo make install 
