#!/bin/bash
DOT_DIR="$HOME/dotfiles"

function usage {
  cat <<EOM
Usage: $(basename "$0") [OPTION]...
  -h[Help]          Display help
  -f[Full-Setup]    Full-setup which will excute deploy/init/env/
  -s[Setup]         Setup default shell.
  -i[Init]          Install tools ignore environment for develop.
  -e[Env]           Install environment for develop.
  -d[Deploy]        Link dotfiles(.)
EOM
  exit 2
}

has() {
    type "$1" > /dev/null 2>&1
}

if [ ! -d ${DOT_DIR} ]; then
    if has "git"; then
        git clone https://github.com/rp-agota/dotfiles.git ${DOT_DIR}
    elif has "curl" || has "wget"; then
        TARBALL="https://github.com/rp-agota/dotfiles/archive/master.tar.gz"
        if has "curl"; then
            curl -L ${TARBALL} -o master.tar.gz
        else
            wget ${TARBALL}
        fi
        tar -zxvf master.tar.gz
        rm -f master.tar.gz
        mv -f dotfiles-master "${DOT_DIR}"
    else
        echo "ERROR: curl or wget or git required!"
        exit 1
    fi

    cd ${DOT_DIR}
    while getopts ":f:s:i:e:d:h" optKey; do
        case "$optKey" in
            f)
                make fullsetup
                exit 0
            s)
                make setup
                exit 0
            i)
                make init
                exit 0
            e)
                make env
                exit 0
            d)
                make deploy
                exit 0
            '-h'|'--help'|* )
                usage
                ;;
        esac
    done
else
    echo "ERROR: dotfiles already exists!"
    exit 1
fi

make setup