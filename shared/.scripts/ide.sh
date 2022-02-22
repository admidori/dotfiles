#!/bin/zsh

# set tmux panes like ide

if [ "$#" -eq 0 ]; then
      tmux split-window -h
      tmux split-window -v
      tmux resize-pane -D 10
      tmux select-pane -t 1
      tmux split-window -h
      tmux select-pane -t 3
else
  case $1 in
    1)
      tmux split-window -v
      tmux resize-pane -D 15
      tmux select-pane -D
      clear
      ;;
    *)
      echo ERROR: "$1" is mistaken optins.
      ;;
  esac
fi
