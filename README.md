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

## AI Sandbox Environments
Reusable Docker Sandbox (v3) kits for isolated AI development and sequential delegation live under [`sandbox/kits/`](sandbox/kits/). See [`sandbox/README.md`](sandbox/README.md) for kit definitions, security architecture, and usage instructions.

# License
MIT (c) 2024–2026 [@admidori](https://github.com/admidori)  
And Thanks to all giants. I'm just standing on their shoulders.  
