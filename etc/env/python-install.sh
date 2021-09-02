#!/bin/bash

echo "------------[PYTHON]---------------"
sudo apt install -y python3.8

echo "------------[PIP]---------------"
wget https://bootstrap.pypa.io/get-pip.py
sudo python3 get-pip.py
pip install -r requirements.txt