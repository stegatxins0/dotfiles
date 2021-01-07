#!/bin/zsh

# Adds `~/.local/bin` to $PATH
export PATH="$PATH:$(du "$HOME/.local/bin" | cut -f2 | paste -sd ':' -)"
export SPOTIFY_CLIENT_ID='df8cf03a26f54ab4b629c5edaf1274da'
export SPOTIFY_CLIENT_SECRET='0102d0aceb064887b38b971c93e1c966'
# Default programs
export EDITOR="nvim"
export TERMINAL="alacritty"
export BROWSER="firefox"

# Clean up
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
export ZDOTDIR="${XDG_CONFIG_HOME:-$HOME/.config}/zsh"
export WINEPREFIX="${XDG_DATA_HOME:-$HOME/.local/share}/wineprefixes/default"
export PASSWORD_STORE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/password-store"
export HISTFILE="${XDG_DATA_HOME:-$HOME/.local/share}/history"

[ "$(tty)" = "/dev/tty1" ] && exec startx
