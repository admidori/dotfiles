#!/bin/bash

echo "----------[ZSH]----------"
sudo apt-get install -y zsh
chsh -s $(which zsh)
exec $SHELL -l