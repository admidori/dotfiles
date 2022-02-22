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
make install OS=Debian(Debian)
make install OS=Arch(Arch Linux)
```  
