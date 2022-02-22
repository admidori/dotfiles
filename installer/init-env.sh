#!/bin/sh
# Set language directory.
mkdir -p ~/docker/python/machine-learning/src
mkdir -p ~/docker/C/dev/src

# Set symbolic link.
cp $MAIN_PATH/env/Dockerfiles/Dockerfile-py-ML ~/docker/python/machine-learning/Dockerfile
cp $MAIN_PATH/env/Dockerfiles/Dockerfile-C-dev ~/docker/C/dev/Dockerfile

ln -sf $MAIN_PATH/env/Dockerfiles/docker-compose.yaml ~/docker/docker-compose.yaml

echo "Complete to setup develop environment!"
