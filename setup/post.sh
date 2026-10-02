#!/usr/bin/env bash

# --------------------------------------------------------------
# Oh My Posh
# --------------------------------------------------------------

curl -s https://ohmyposh.dev/install.sh | bash -s -- -d ~/.local/bin

# --------------------------------------------------------------
# ML4W Settings App
# --------------------------------------------------------------

bash <(curl -s https://raw.githubusercontent.com/mylinuxforwork/ml4w-dotfiles-settings/main/setup.sh)

# --------------------------------------------------------------
# Quickshell Overview
# --------------------------------------------------------------

bash <(curl -s https://raw.githubusercontent.com/mylinuxforwork/ml4w-quickshell-overview/main/install.sh)

# --------------------------------------------------------------
# ML4W Dock
# --------------------------------------------------------------

bash <(curl -s https://raw.githubusercontent.com/mylinuxforwork/ml4w-dock/main/install.sh)

# --------------------------------------------------------------
# ML4W Power Menu
# --------------------------------------------------------------

bash <(curl -s https://raw.githubusercontent.com/mylinuxforwork/ml4w-powermenu/main/install.sh)

# --------------------------------------------------------------
# ML4W Walker (app launcher + its provider daemon, elephant)
# --------------------------------------------------------------

# ml4w-walker's own distro detection only matches arch/fedora/
# opensuse-tumbleweed/ubuntu and exits 1 on Debian, so install its
# runtime deps ourselves (same as its own base_packages() +
# provider_packages() would for a recognized distro: libgtk-4-1/
# libgtk4-layer-shell0/libpoppler-glib8t64 for the binary-mode base
# install, wl-clipboard/imagemagick for the clipboard provider added
# below) and skip its detection with --no-deps.
#
# Subshell-scoped read (matching ml4w-walker's own detect_distro(),
# which does the same) instead of sourcing /etc/os-release directly
# into this script -- that would leak ID/VERSION_ID/PRETTY_NAME/etc.
# into every step below for the rest of this file's run.
debian_id="$(. /etc/os-release 2>/dev/null && echo "${ID:-}")"
if [ "$debian_id" = "debian" ]; then
    sudo apt-get install -y \
        libgtk-4-1 libgtk4-layer-shell0 libpoppler-glib8t64 \
        wl-clipboard imagemagick
    bash <(curl -s https://raw.githubusercontent.com/mylinuxforwork/ml4w-walker/main/install.sh) --no-deps
else
    bash <(curl -s https://raw.githubusercontent.com/mylinuxforwork/ml4w-walker/main/install.sh)
fi
ml4w-walker add clipboard

# --------------------------------------------------------------
# Cursors
# --------------------------------------------------------------

source $repo_path/setup/_cursors.sh

# --------------------------------------------------------------
# Fonts
# --------------------------------------------------------------

source $repo_path/setup/_fonts.sh

# --------------------------------------------------------------
# Icons
# --------------------------------------------------------------

source $repo_path/setup/_icons.sh

# --------------------------------------------------------------
# Create XDG Directories
# --------------------------------------------------------------

xdg-user-dirs-update