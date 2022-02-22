#!/bin/sh

echo "########################"
echo "#      SETUP ENV.      #"
echo "########################"

# Make working directory
mkdir -p ~/docker/python/machine-learning/src
mkdir -p ~/docker/C/dev/src

# Copy Dockerfiles
cp $MAIN_PATH/env/Dockerfiles/py-ML ~/docker/python/machine-learning/Dockerfile
cp $MAIN_PATH/env/Dockerfiles/c-dev ~/docker/C/dev/Dockerfile
ln -sf $MAIN_PATH/env/Dockerfiles/docker-compose.yaml ~/docker/docker-compose.yaml

echo "Complete to setup environment!"
