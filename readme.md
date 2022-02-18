# Dotfiles (Arch/Debian)  
## STEP 1 --install git  
- Arch 
```sudo pacman -Syu --noconfirm git```  
- Debian  
```sudo apt update && apt upgrade```  
```sudo apt -y install git```  
  
## STEP 2 --install dotfiles  
```git clone https://github.com/rp-agota/dotfiles.git```  
  
## STEP 3 --Permission setting and install dots and more.  
```
cd dotfiles
chmod 777 install.sh
./install.sh
```  
  
## STEP 4 --zsh install 
```
cd dotfiles
chmod 777 zshsetup.sh
./zshsetup.sh
```  
