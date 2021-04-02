#!/bin/bash

echo "----------[ZSH]----------"
sudo apt update
sudo apt-get install -y zsh
chsh -s $(which zsh)