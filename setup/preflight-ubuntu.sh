#!/usr/bin/env bash

# Oh My Posh, pipx, and cargo all install into ~/.local/bin (or expect it
# to already be there) -- on a genuinely fresh account it doesn't exist
# yet. Confirmed live on a clean VM.
mkdir -p "$HOME/.local/bin"

# --------------------------------------------------------------
# Repositories
# --------------------------------------------------------------

# gum isn't installed yet at this point in a fresh run (it's installed at
# the end of this script), so these early repository-setup steps are
# quieted with plain log redirection rather than `gum spin`.
sudo apt-get install -y software-properties-common >> "${LOG_FILE:-/dev/null}" 2>&1
sudo add-apt-repository -y universe >> "${LOG_FILE:-/dev/null}" 2>&1
sudo add-apt-repository -y restricted >> "${LOG_FILE:-/dev/null}" 2>&1

# Hyprland core (hyprland, hypridle, hyprlock, hyprpicker, hyprsunset,
# hyprpolkitagent, hyprland-guiutils, xdg-desktop-portal-hyprland)
if ! grep -Rq "cppiber.*hyprland" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    info "Adding PPA: ppa:cppiber/hyprland"
    sudo add-apt-repository -y ppa:cppiber/hyprland >> "${LOG_FILE:-/dev/null}" 2>&1
else
    info "Hyprland PPA already present"
fi

# cliphist (quickshell is built from source in post-ubuntu.sh instead of
# using this PPA's quickshell-git package, to match the exact commit
# already validated to work)
if ! grep -Rq "avengemedia.*danklinux" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    info "Adding PPA: ppa:avengemedia/danklinux"
    sudo add-apt-repository -y ppa:avengemedia/danklinux >> "${LOG_FILE:-/dev/null}" 2>&1
else
    info "danklinux PPA already present"
fi

# gum (not available in Ubuntu main/universe)
if [ ! -f /etc/apt/keyrings/charm.gpg ]; then
    info "Adding Charm apt repo for gum"
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list > /dev/null
else
    info "Charm apt repo already present"
fi

# Firefox: plain `apt-get install firefox` on Ubuntu installs a
# transitional snap wrapper, not a native .deb (Ubuntu dropped the deb
# from the archive in 22.04+). Add the Mozilla Team PPA and pin it above
# the snap-transitional package so the shared packages file's `firefox`
# entry resolves to a real .deb, matching what Arch/Fedora/openSUSE get.
if ! grep -Rq "mozillateam.*ppa" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    info "Adding PPA: ppa:mozillateam/ppa (native Firefox .deb, not the snap)"
    sudo add-apt-repository -y ppa:mozillateam/ppa >> "${LOG_FILE:-/dev/null}" 2>&1
fi
sudo tee /etc/apt/preferences.d/mozilla-firefox > /dev/null <<-'EOF'
	Package: *
	Pin: release o=LP-PPA-mozillateam
	Pin-Priority: 1001
	EOF
sudo tee /etc/apt/apt.conf.d/51unattended-upgrades-firefox > /dev/null <<-'EOF'
	Unattended-Upgrade::Allowed-Origins:: "LP-PPA-mozillateam:${distro_codename}";
	EOF

sudo apt-get update >> "${LOG_FILE:-/dev/null}" 2>&1

# gum: only the repo was added above -- install it explicitly now rather
# than leaving it to whatever later step happens to apt-get install it
# first (previously that was the ML4W Settings App's patched bootstrap
# line in post-ubuntu.sh, which meant nothing before that point --
# including the package loop and dotfiles rsync in install-ubuntu.sh --
# could use `gum spin` for quiet output).
if ! command -v gum &> /dev/null; then
    sudo apt-get install -y gum >> "${LOG_FILE:-/dev/null}" 2>&1
fi

# --------------------------------------------------------------
# Uninstall swww if exists. To be replaced with awww in the next steps
# --------------------------------------------------------------

if dpkg -l 2>/dev/null | grep -q "^ii  swww "; then
    sudo apt-get remove -y swww >> "${LOG_FILE:-/dev/null}" 2>&1
fi
