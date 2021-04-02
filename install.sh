#!/bin/bash

#Welcome to install.sh

#[動作確認済環境]
#macOS Big Sur

echo "Hello! This is the install.sh!"

echo "----------[FIRST STEP]----------"
#各dotfileのSymbolic linkをホームディレクトリに貼り付ける
echo "make Symbolic link of dotfiles!"
chmod +x link.sh
./link.sh


echo "----------[SECOND STEP]----------"
#OS固有の設定をインストールする
echo "Now which do  you use computer?"
echo "Macintosh->1"
echo "Linux->2"
read -p "Answer:" OSname

#Macの場合FLG_OSがMACになる
if [ "$OSname" = "1" ]; then
   FLG_OS="MAC"
fi
#Linuxの場合FLG_OSがLINUXになる
if [ "$OSname" = "2" ]; then
   FLG_OS="LINUX"
fi

if [ "$FLG_OS" = "MAC" ]; then
  cd ~/dotfiles/etc/init/mac/
  chmod +x setupmac.sh
  ./setupmac.sh
fi

if [ "$FLG_OS" = "LINUX" ]; then
  cd ~/dotfiles/etc/init/linux/
  chmod +x setuplinux.sh
  ./setuplinux.sh
fi


echo "----------[THIRD STEP]----------"
#各開発環境をインストールする
#開発環境が必要になった場合インストールコマンドを~/dotfiles/bin/toolにsh形式で入れると次回セットアップ時に自動実行する
echo "Begin to setup deleloping tool"

if [ "$FLG_OS" = "MAC" ]; then
echo "----------[Homebrew installing]----------"
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install.sh)"
cd ~/dotfiles/bin/tool/mac/
for f in *.sh
do
    echo "----$f installing----"
    chmod +x $f
    ./$f
    echo "----$f installed!----"
done
fi

if [ "$FLG_OS" = "LINUX" ]; then
cd ~/dotfiles/bin/tool/linux/
for f in *.sh
do
    echo "----$f installing----"
    chmod +x $f
    ./$f
    echo "----$f installed!----"
done
fi

echo "----------[FOURTH STEP]----------"
#開発には直接関係の無いオプション(powerlineなど)をインストールする
#同様に~/dotfiles/bin/optionにsh形式で入れると次回セットアップ時に自動続行する
echo "Begin to setup option tool"

if [ "$FLG_OS" = "MAC" ]; then
cd ~/dotfiles/bin/option/mac
for f in *.sh
do
    echo "----$f installing...----"
    chmod +x $f
    ./$f
    echo "----$f installed!----"
done
fi

if [ "$FLG_OS" = "LINUX" ]; then
cd ~/dotfiles/bin/option/linux
for f in *.sh
do
    echo "----$f installing...----"
    chmod +x $f
    ./$f
    echo "----$f installed!----"
done
fi

echo "----------[FINAL STEP]----------"
#githubの設定を行う
echo "Begin to setup git and github"
echo "What is your git name?:"
read gitname
echo "What is your git email?"
read gitemail

git config --global user.name"$gitname"
git config --global user.email $gitmail

echo "----------[INSTALL ENDED!]----------"
echo "Thank you for using this install script."
echo "Good bye and Enjoy new computer!"
