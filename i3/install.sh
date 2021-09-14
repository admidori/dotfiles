#!/bin/bash
sudo pacman -Syu --noconfirm xf86-video-intel    # Video card
sudo pacman -Syu --noconfirm xorg-server xorg-xinit xterm i3-wm i3status
sudo pacman -Syu --noconfirm ightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings
sudo pacman -Syu --noconfirm dmenu compton lxappearance ttf-dejavu otf-ipafont

#enable lightdm
systemctl enable lightdm
systemctl reboot