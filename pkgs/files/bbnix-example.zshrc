# bbnix example ~/.zshrc -- a reference, NOT loaded automatically.
#
# Copy whatever you want from here into your own ~/.zshrc. The bbnix bundle
# already puts the full zsh function tree + run-help on your $fpath / $HELPDIR
# (FPATH and HELPDIR are set relocatably by etc/bbnix-env), so the completion
# system is available; you just have to turn it on.

# Enable the completion system. `-i` skips the "insecure directories" prompt --
# the bundle's function dir is owned by the app uid, which compinit's security
# audit would otherwise flag. The dump goes to a writable path under $HOME.
autoload -Uz compinit
compinit -i -d "${XDG_CACHE_HOME:-$HOME}/.zcompdump"

# --- everything below is optional taste; uncomment what you like ---

# Completion behaviour
# zstyle ':completion:*' menu select                          # arrow-key menu
# zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'   # case-insensitive
# zstyle ':completion:*' list-colors ''

# History
# HISTFILE=$HOME/.zsh_history
# HISTSIZE=10000
# SAVEHIST=10000
# setopt SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE EXTENDED_HISTORY

# Navigation / globbing / input
# setopt AUTO_CD EXTENDED_GLOB INTERACTIVE_COMMENTS
# bindkey -e                                                  # emacs keymap

# run-help (try: run-help cd) -- alias the builtin out of the way first
# unalias run-help 2>/dev/null
# autoload -Uz run-help

# A plain prompt
# PROMPT='%n@%m %~ %# '
