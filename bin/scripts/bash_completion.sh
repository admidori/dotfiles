#!/bin/bash

sudo apt update
sudo apt install -y bash-completion curl
sudo curl -L https://raw.githubusercontent.com/docker/compose/1.29.2/contrib/completion/bash/docker-compose -o /etc/bash_completion.d/docker-compose

