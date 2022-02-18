# ----------Environmental path----------
# pyenv
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/shims:$PATH"
eval "$(pyenv init --path)"
# anaconda
. /Users/agota/.pyenv/versions/anaconda3-5.3.1/etc/profile.d/conda.sh
# ----------Path END----------