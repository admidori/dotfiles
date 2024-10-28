#!/bin/sh

git clone https://github.com/nvm-sh/nvm.git ~/.nvm
cd ~/.nvm
git checkout `git describe --tags --abbrev=0`
. ./nvm.sh

