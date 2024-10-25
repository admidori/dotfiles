#!/bin/sh

sudo apt update
sudo apt install -y fzf

mkdir -P ../../vendor/cdhist 
wget -P ../../vendor/cdhist https://www.unixuser.org/~euske/doc/bashtips/cdhist.sh
