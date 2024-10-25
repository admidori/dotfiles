#!/bin/sh

sudo apt update
sudo apt install -y openssh-server openssh-client
ssh-keygen -t ed25519 -N ""
ssh-add ~/.ssh/id_ed25519
