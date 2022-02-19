#!/bin/sh
# Set language directory.
mkdir -p ~/docker/python/machine-learning/share
mkdir -p ~/docker/C/dev/share

# Set symbolic link.
ln -sf ~/dotfiles/env/Dockerfiles/Dokcerfile-py-ML ~/docker/python/machine-learning/Dockerfile
ln -sf ~/dotfiles/env/Dockerfiles/Dockerfile-C-dev ~/docker/C/dev/Dockerfile

ln -sf ~/dotfiles/env/Dockerfiles/docker-compose.yaml ~/docker/docker-compose.yaml

echo "Complete to setup develop environment!"
