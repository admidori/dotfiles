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
  echo "$f Unlinked."
done

# Unlink .claude config files individually
for f in ~/.claude/.*
do
  if [ -L "$f" ]; then
    unlink "$f"
    echo ".claude/$(basename $f) Unlinked."
  fi
done
