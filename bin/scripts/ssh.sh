#!/bin/sh

sudo apt install openssh-server openssh-client
ssh-keygen -t ed25519 -N ""
ssh-add ~/.ssh/id_ed25519
