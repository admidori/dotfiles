#!/bin/bash

echo "########################"
echo "#  MAKE SYMBOLIC LINK  #"
echo "########################"
cd ~/
for f in .??*
do
  if [ -L $f ]; then
    unlink ./$f
  fi
done

cd $MAIN_PATH/bin/dotfiles
for f in .??*
do
  [[ "$f" == ".gitignore" ]] && continue
  [[ "$f" == ".claude" ]] && continue
  ln -sf $MAIN_PATH/bin/dotfiles/$f ~/$f
  echo "linked $f"
done

# Link .claude config files individually to avoid overwriting runtime data
mkdir -p ~/.claude
for f in $MAIN_PATH/bin/dotfiles/.claude/.*
do
  fname=$(basename "$f")
  [[ "$fname" == "." || "$fname" == ".." || "$fname" == ".gitignore" ]] && continue
  ln -sf "$f" ~/.claude/"$fname"
  echo "linked .claude/$fname"
done
