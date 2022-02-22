#!/bin/sh
echo "########################"
echo "# UNLINK SYMBOLIC LINK #"
echo "########################"
cd ~/
for f in .??*
do
  if [ -L $f ]; then
    unlink ./$f
  fi
done
