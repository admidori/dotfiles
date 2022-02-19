#!/bin/sh
cd ~/
for f in .??*
do
  if [ -L $f ]; then
    unlink ./$f
  fi
done
