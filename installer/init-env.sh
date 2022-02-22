#!/bin/sh
# Set language directory.
mkdir -p ~/docker/python/machine-learning/src
mkdir -p ~/docker/C/dev/src

# Set symbolic link.
cp ~/dotfiles/env/Dockerfiles/Dockerfile-py-ML ~/docker/python/machine-learning/Dockerfile
cp ~/dotfiles/env/Dockerfiles/Dockerfile-C-dev ~/docker/C/dev/Dockerfile

ln -sf ~/dotfiles/env/Dockerfiles/docker-compose.yaml ~/docker/docker-compose.yaml

echo "Complete to setup develop environment!"
