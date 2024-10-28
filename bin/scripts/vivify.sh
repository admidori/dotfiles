#!/bin/sh

wget -O - https://github.com/jannis-baum/Vivify/releases/download/v0.6.0/vivify-linux.tar.gz | tar xvfz - -C ../../vendor
mv ../../vendor/vivify-linux ../../vendor/vivify
