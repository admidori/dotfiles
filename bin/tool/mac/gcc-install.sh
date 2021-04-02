#!/bin/bash

echo "----------[GCC]----------"
brew update
brew install gcc
sudo ln -sf $(ls -d /usr/local/bin/* | grep "/g++-" | sort -r | head -n1) /usr/local/bin/g++