# Dotfiles  
開発用PCのdotfilesです。
自分のニーズに最大限合わせているので傍から見れば基本的に不必要なものが多いです。
サーバー用→[rp-agota/dotfiles-server](https://github.com/rp-agota/dotfiles-server)

# 動作確認済環境
macOS Big Sur  
Ubuntu 20.04  

# How to install  
 ```
 git clone https://github.com/rp-agota/dotfiles.git
 cd dotfiles  
 chmod +x install.sh
 ./install.sh
 ```  

# How to maintenance
 ルートディレクトリに置かれるdotfilesは全てこのリポジトリのシンボリックリンクになっています。  
 dotfilesを変更したら定期的にcommit & pushしてあげてください。

 # ディレクトリ構造
 ```
 root/
　├ bin/ (スクリプトファイルなど)
　│　└ tool/　（開発ツール導入用のスクリプトファイル）
　│　     └ /linux
　│　             └...
　│　             └ ~install.sh
　│　             └...
　│　     └ /mac
　│　             └...
　│　             └ ~install.sh
　│　             └...
　│　             
　│　└ env/　　（環境構築用のスクリプトファイル）
　│　     └ /linux
　│　             └...
　│　             └ ~install.sh
　│　             └...
　│　     └ /mac
　│　             └...
　│　             └ ~install.sh
　│　             └...
　│
　│　└ etc/　（その他手動でインストールするスクリプトファイル）
　│　      └zplug-install.sh (zplug)
　│
　├　install.sh (インストール用のスクリプトファイル)
　│　             
　├　link.sh    (dotfilesのシンボリックリンクを貼るためのスクリプトファイル)
　│　             
　├　...
　├　dotfiles   (各dotfiles)
　└  ...

 MacではHomebrew、Linuxではapt-getを使用しています。
 ```
 
 # 構築環境
 ・python3.8  
 ・pip(詳細はrequirement.txt参照)  
 ・gcc  

 # 開発ツール
 ・zsh & zplug  
 ・vim  
 ・Midnight Commander    
 ・tmux  