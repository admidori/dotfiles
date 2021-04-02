#!/bin/bash

echo "------------[PYTHON]---------------"
brew update
brew install python

echo "------------[PIP]---------------"
curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
python3 get-pip.py
pip install -r requirements.txt