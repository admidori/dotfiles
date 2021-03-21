# Dotfiles  
[動作確認済環境]  
macOS Big Sur  

# How to install  
 ```
 $ git clone https://github.com/rp-agota/dotfiles.git
 $ cd dotfiles  
 $ ./install.sh
 ```  
 
 # ディレクトリ構造
 ```
 root/
　├ bin/
　│　└ option/　（開発に直接必要のないツールなどのスクリプトファイル）
　│　     └ /linux
　│　             └ ~install.sh files
　│　     └ /mac
　│　└ tool/　　（環境構築用のスクリプトファイル）
　│　     └ /linux
　│　            └ ~install.sh files
　│　     └ /mac
　├ etc/
　│　└ init/　　（環境依存のdotfile）
　│　     └ /linux
　│　           └ setuplinux.sh
　│　           └ dotfiles
　│　     └ /mac
　│　           └ setupmac.sh
　│　           └ dotfiles
　├　install.sh
　├　link.sh
　└  dotfiles
 ```
 
