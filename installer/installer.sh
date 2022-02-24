if type "git" > /dev/null 2>&1; then
		git clone https://github.com/rp-agota/dotfiles.git ~/dotfiles
		echo "Which your Linux destribution?"
		echo "Debian-> 1"
		echo "Arch Linux-> 2"
		read -p "Press number>" number
		case "$number" in
			[1])
				cd ~/dotfiles
				make install OS=debian
				;;
			[2])
				cd ~/dotfiles
				make install OS=Arch
				;;
			*)
				echo "[Error] Undefined number."
				exit 1
				;;
		esac
else
    echo "[Error] git doesn't exist!"
		exit 1
fi

