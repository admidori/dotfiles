# admidori/dotfiles  
## Basic installation  
```
sh -c "$(curl -fsSL https://raw.githubusercontent.com/admidori/dotfiles/master/installer/installer.sh)"
```

## Manual installation  
```
git clone https://github.com/admidori/dotfiles.git
cd dotfiles
make install
```  

## Requirements software
- bash
- GNU make
- git
- curl

## Running the tests
The installer can be exercised on a clean Debian system without touching your
machine, using Docker:
```
make test
```
This builds the image from `Dockerfile` and runs `installer/test.sh`, which
performs a full `make install` and verifies the symlinks and oh-my-zsh setup.

## WSL keyring unlock with 1Password
After linking the dotfiles, run `keyring-unlock` in your WSL zsh session before
using tools that need the login keyring. The Windows 1Password app must have
CLI integration enabled. The configured field
`op://Credentials/WSL Keyring/password` must contain the existing GNOME login
keyring password, not a newly generated password.

The command reads the field only when the keyring is locked, so Windows Hello
may request approval. It uses the existing daemon's control socket; it does
not launch or replace a keyring daemon, create a keyring, or print/store the
password. D-Bus may start its registered Secret Service provider on demand.
Run it as your normal WSL user, without sudo.

This is a host-side command. Do not copy the password or the host control
socket into an AI sandbox. 1Password locking does not re-lock an already
unlocked GNOME keyring. OAuth tokens remain in the GNOME keyring.

The helper requires Python 3, busctl, GNOME Keyring, and the Windows CLI.
The control protocol is GNOME-specific, rather than the portable Secret
Service API. Missing keyrings, mismatched daemon/socket ownership, denied
passwords, and timeouts cause failure instead of a plaintext fallback.
The command and its optional reference/executable overrides can also be used
directly:

```sh
/usr/bin/python3 -I ~/.keyring/unlock.py --help
python3 -I installer/test-keyring-unlock.py
```

# License
MIT (c) 2024–2026 [@admidori](https://github.com/admidori)  
And Thanks to all giants. I'm just standing on their shoulders.  
