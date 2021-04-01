# Dotfiles  
完全に自分用の開発用PCのdotfilesです。
自分のニーズに最大限合わせているので傍から見れば基本的に不必要なものが多いです。

[動作確認済環境]  
macOS Big Sur  
Ubuntu 20.04

# How to install  
 ```
 $ git clone https://github.com/rp-agota/dotfiles.git
 $ cd dotfiles  
 $ chmod +x install.sh
 $ ./install.sh
 ```  
 
 # ディレクトリ構造
 ```
 root/
　├ bin/ (スクリプトファイルなど)
　│　└ option/　（開発に直接必要のないツールなどのスクリプトファイル）
　│　     └ /linux
　│　             └ ~install.sh files
　│　     └ /mac
　│　└ tool/　　（環境構築用のスクリプトファイル）
　│　     └ /linux
　│　            └ ~install.sh files
　│　     └ /mac
　├ etc/ (複雑なdotfileなど)
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
 
 # 構築される環境（どんどん増えます）
 ・python3.8  
 ・pip(詳細はrequirement.txt参照)  
 ・gcc  

 # オプションでインストールされるソフト(必要に応じで消えたり増えたりします）
 ・Midnight Commander  
 ・Powerline  
 ・tmux  
