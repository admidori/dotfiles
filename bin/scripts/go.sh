#!/bin/sh

sudo apt update
sudo apt install -y gccgo-5
sudo update-alternatives --set go /usr/bin/go-5
GOROOT_BOOTSTRAP=/usr ./make.bash

git clone https://github.com/golang/go.git ../tmp
cd ../tmp/go
git checkout `git describe --tags --abbrev=0`
cd src
sudo chmod 777 all.bash
./all.bash

