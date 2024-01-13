#!/bin/bash

echo "########################"
echo "#  MAKE SYMBOLIC LINK  #"
echo "########################"
cd $MAIN_PATH/bin/dotfiles
for f in .??*
do
  [[ "$f" == ".gitignore" ]] && continue
  ln -sf $MAIN_PATH/bin/dotfiles/$f ~/$f
  echo "linked $f"
done
