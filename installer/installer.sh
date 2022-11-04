if type "git" > /dev/null 2>&1; then
	echo "Start installing dotfiles for Macintosh..."
	git clone https://github.com/rp-agota/dotfiles.git ~/dotfiles
	cd dotfiles
	sudo make install
else
    echo "[Error] git doesn't exist!"
	exit 1
fi

