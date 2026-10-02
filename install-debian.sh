#!/usr/bin/env bash

# Debian 13 installer for ML4W OS -- local testing scaffold.
#
# The real installer (bash <(curl -s https://ml4w.com/os/rolling)) clones
# github.com/mylinuxforwork/ml4w-dotfiles-installer, whose distro detection
# (get_distro_by_bin in lib/helpers.sh) only recognizes pacman/dnf/zypper/
# apt and hard-exits on anything else -- Debian is not reachable through it
# today. This script replicates the same setup/preflight -> packages ->
# setup/post dispatch so this repo's Debian support can be exercised end
# to end without waiting on a companion change there.
#
# Known, deliberate differences from the real installer:
#   - Deployment here is a flat `rsync -av dotfiles/ $HOME/` copy. The real
#     installer stages into ~/.mydotfiles/<profile_id>/ and symlinks each
#     top-level entry (and each .config child) into $HOME instead.
#   - Restore handling here is unconditional (back up and restore every
#     dotinst restore-manifest entry). The real installer is interactive.
#   - The real installer also shows an interactive `gum confirm` profile
#     summary before doing anything; this script has none.
#   - Package installs here are best-effort: a failed `apt-get install` is
#     logged to ~/.ml4w-missing-packages.log and the loop continues rather
#     than aborting.

set -e

repo_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export repo_path

# Provide the info/warn/error helpers that setup/*.sh scripts expect from
# the real installer framework.
info() { echo -e "\033[0;32m[INFO]\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*" >&2; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }
export -f info warn error

dotinst_file="$repo_path/hyprland-dotfiles.dotinst"
backup_dir="$HOME/.ml4w-backup-$(date +%Y%m%d-%H%M%S)"

# A long install can easily outlast sudo's credential cache (typically
# 15 min), and a password re-prompt during a background step would be
# invisible -- indistinguishable from a genuine hang. Keep the sudo
# timestamp alive for the whole run instead. Requires the initial `sudo -v`
# below to succeed interactively before anything else starts.
sudo -v
( while kill -0 $$ 2>/dev/null; do sudo -n true; sleep 60; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT

# --------------------------------------------------------------
# Require Debian 13 -- hard stop on anything else
# --------------------------------------------------------------

if [ -f /etc/os-release ]; then
    source /etc/os-release
    if [[ "$ID" != "debian" ]]; then
        error "This script is for Debian only. Detected: $ID $VERSION_ID"
        error "For Arch/Fedora/openSUSE use: bash <(curl -s https://ml4w.com/os/rolling)"
        exit 1
    fi
    debian_major="${VERSION_ID%%.*}"
    if [[ ! "$debian_major" =~ ^[0-9]+$ ]] || [ "$debian_major" -lt 13 ]; then
        error "This requires Debian 13 (trixie) or later (hyprland/quickshell are only"
        error "packaged from trixie-backports onward). Detected: $VERSION_ID"
        exit 1
    fi
    info "Detected: $PRETTY_NAME"
else
    error "Cannot detect OS (/etc/os-release missing). Aborting."
    exit 1
fi

# --------------------------------------------------------------
# Bootstrap prerequisites
# --------------------------------------------------------------

info "Installing bootstrap prerequisites"
sudo apt-get update -y
sudo apt-get install -y git curl jq rsync make build-essential

# --------------------------------------------------------------
# Preflight (repositories + backports)
# --------------------------------------------------------------

info "Running preflight"
source "$repo_path/setup/preflight-debian.sh"

# --------------------------------------------------------------
# Package installation
# --------------------------------------------------------------

MISSING_LOG="$HOME/.ml4w-missing-packages.log"
echo "# ml4w Debian install -- missing packages -- $(date)" > "$MISSING_LOG"

install_package_file() {
    local file=$1
    [ -f "$file" ] || return 0
    info "Installing packages from $(basename "$file")"
    while IFS= read -r pkg || [ -n "$pkg" ]; do
        pkg=$(echo "$pkg" | sed "s/#.*//" | xargs)
        [ -z "$pkg" ] && continue
        sudo apt-get install -y "$pkg" || echo "$pkg" >> "$MISSING_LOG"
    done < "$file"
}

install_package_file "$repo_path/setup/dependencies/packages"
install_package_file "$repo_path/setup/dependencies/packages-debian"

if [ -s "$MISSING_LOG" ]; then
    warn "Some packages could not be installed -- see $MISSING_LOG"
fi

# --------------------------------------------------------------
# Dotfiles deployment -- back up restore entries first
# --------------------------------------------------------------

info "Preparing dotfiles deployment"

mapfile -t restore_sources < <(
    jq -r '.restore[] | select(.value == true) | .source' "$dotinst_file"
)

if [ ${#restore_sources[@]} -gt 0 ]; then
    mkdir -p "$backup_dir"
    for src in "${restore_sources[@]}"; do
        target="$HOME/$src"
        if [ -e "$target" ] || [ -L "$target" ]; then
            parent_in_backup="$backup_dir/$(dirname "$src")"
            mkdir -p "$parent_in_backup"
            cp -a "$target" "$parent_in_backup/"
            info "Backed up: ~/$src"
        fi
    done
fi

info "Deploying dotfiles from $repo_path/dotfiles/"
rsync -a "$repo_path/dotfiles/" "$HOME/"

# The real installer always creates ~/.mydotfiles/<profile_id>/ as part of
# its stage-then-symlink deployment -- this harness's flat rsync doesn't,
# but autostart.lua unconditionally redirects ml4w-autostart's output to
# ~/.mydotfiles/ml4w-autostart.log. Bash can't create a file under a
# missing parent directory, so without this the whole
# `ml4w-autostart > ~/.mydotfiles/ml4w-autostart.log 2>&1` command fails
# before ml4w-autostart ever runs -- silently, no log, and nothing it
# launches (including quickshell) ever starts.
mkdir -p "$HOME/.mydotfiles"

if [ -d "$backup_dir" ]; then
    info "Restoring preserved user configs"
    for src in "${restore_sources[@]}"; do
        backed_up="$backup_dir/$src"
        if [ -e "$backed_up" ] || [ -L "$backed_up" ]; then
            parent_in_home="$HOME/$(dirname "$src")"
            mkdir -p "$parent_in_home"
            cp -a "$backed_up" "$parent_in_home/"
            info "Restored: ~/$src"
        fi
    done
fi

# --------------------------------------------------------------
# Post-install (build tools, awww, matugen, etc.)
# --------------------------------------------------------------

info "Running post-install"
source "$repo_path/setup/post-debian.sh"

# post.sh (Oh My Posh, ML4W Settings App, Quickshell Overview, ML4W
# Dock, ML4W Walker, Cursors, Fonts, Icons, XDG dirs -- the steps
# shared with every other distro) is run as a separate process, not
# sourced, so its lack of `set -e` isolates its steps from each other
# and from this script's own set -e. That matters specifically for
# the ML4W Settings App step: its distro detection doesn't know apt
# either and exits 1, and post.sh has no error handling of its own to
# skip past that -- sourcing it here would abort the whole install at
# that line instead of continuing to ML4W Walker/Dock/Cursors/Fonts/
# Icons/XDG below it.
info "Running shared post-install (post.sh)"
bash "$repo_path/setup/post.sh"

# --------------------------------------------------------------

echo ""
info "ML4W OS installation complete."
if [ -d "$backup_dir" ]; then
    info "Backup of pre-existing configs: $backup_dir"
fi
if [ -s "$MISSING_LOG" ]; then
    info "Packages that could not be installed: $MISSING_LOG"
fi
info "Log out and back in (or reboot) to start your Hyprland session."
