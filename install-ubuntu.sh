#!/usr/bin/env bash

# Ubuntu 26.04 installer for ML4W OS -- local testing scaffold.
#
# The real installer (bash <(curl -s https://ml4w.com/os/rolling)) doesn't
# recognize Ubuntu (its distro detection only knows pacman/dnf/zypper), so
# this replicates its preflight -> packages -> post dispatch to exercise
# Ubuntu support without waiting on a companion change there.
#
# Deliberate differences from the real installer: flat rsync deploy
# instead of stage-then-symlink (anything assuming a symlink, e.g.
# migration.sh's `[ -L $NVIM_DIR ]` check, won't behave identically);
# restore is unconditional, not an interactive picker; no profile
# confirmation prompt; package installs are best-effort (failures logged
# to ~/.ml4w-missing-packages.log, loop continues).

set -euo pipefail

repo_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export repo_path

# info/warn/error: setup/*.sh call these but don't define them
# themselves -- the real installer normally provides them.
info() { echo -e "\033[0;32m[INFO]\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*" >&2; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }
export -f info warn error

dotinst_file="$repo_path/hyprland-dotfiles.dotinst"
backup_dir="$HOME/.ml4w-backup-$(date +%Y%m%d-%H%M%S)"

# Minimal LOG_FILE for the bootstrap step below; preflight-ubuntu.sh
# truncates and takes over the same path once it runs.
LOG_FILE="$HOME/.ml4w-install.log"
: > "$LOG_FILE"
export LOG_FILE

# --------------------------------------------------------------
# Require Ubuntu -- hard stop on anything else
# --------------------------------------------------------------

if [ -f /etc/os-release ]; then
    source /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        error "This script is for Ubuntu only. Detected: $ID $VERSION_ID"
        error "For Arch/Fedora/openSUSE use: bash <(curl -s https://ml4w.com/os/rolling)"
        exit 1
    fi
    ubuntu_major="${VERSION_ID%%.*}"
    if [[ ! "$ubuntu_major" =~ ^[0-9]+$ ]] || [ "$ubuntu_major" -lt 26 ]; then
        error "This requires Ubuntu 26.04 or later (the Hyprland/quickshell PPAs used here"
        error "are not validated on older releases). Detected: $VERSION_ID"
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
# gum isn't installed yet, so plain log redirection instead of gum spin.
sudo apt-get update -y >> "$LOG_FILE" 2>&1
sudo apt-get install -y git curl jq rsync make build-essential >> "$LOG_FILE" 2>&1

# --------------------------------------------------------------
# Preflight (repositories + PPA)
# --------------------------------------------------------------

info "Running preflight"
source "$repo_path/setup/preflight-ubuntu.sh"

# --------------------------------------------------------------
# Package installation
# --------------------------------------------------------------

MISSING_LOG="$HOME/.ml4w-missing-packages.log"
echo "# ml4w Ubuntu install -- missing packages -- $(date)" > "$MISSING_LOG"

install_package_file() {
    local file=$1
    [ -f "$file" ] || return 0
    # One spinner for the whole file (can run past 80 packages); failures
    # are logged to MISSING_LOG, not printed live.
    run_quiet "Installing packages from $(basename "$file")" bash -c '
        while IFS= read -r pkg || [ -n "$pkg" ]; do
            pkg=$(echo "$pkg" | sed "s/#.*//" | xargs)
            [ -z "$pkg" ] && continue
            sudo apt-get install -y "$pkg" >> "$2" 2>&1 || echo "$pkg" >> "$1"
        done < "$3"
    ' _ "$MISSING_LOG" "$LOG_FILE" "$file"
}

install_package_file "$repo_path/setup/dependencies/packages"
install_package_file "$repo_path/setup/dependencies/packages-ubuntu"

if [ -s "$MISSING_LOG" ]; then
    warn "Some packages could not be installed -- see $MISSING_LOG"
fi

# --------------------------------------------------------------
# Dotfiles deployment -- back up restore entries first
# --------------------------------------------------------------

info "Preparing dotfiles deployment"

if ! restore_json=$(jq -r '.restore[] | select(.value == true) | .source' "$dotinst_file"); then
    error "Failed to read restore manifest: $dotinst_file"
    exit 1
fi
mapfile -t restore_sources <<<"$restore_json"
if [ ${#restore_sources[@]} -eq 1 ] && [ -z "${restore_sources[0]}" ]; then
    restore_sources=()
fi

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

run_quiet "Deploying dotfiles from $repo_path/dotfiles/" \
    rsync -a "$repo_path/dotfiles/" "$HOME/"

# autostart.lua redirects ml4w-autostart's output to
# ~/.mydotfiles/ml4w-autostart.log, but this harness's flat rsync (unlike
# the real installer) never creates that directory -- without this, the
# redirect fails silently and nothing it launches (including quickshell)
# ever starts.
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
# Post-install (build tools, awww, quickshell, matugen, etc.)
# --------------------------------------------------------------

info "Running post-install"
source "$repo_path/setup/post-ubuntu.sh"

# post.sh (Oh My Posh, ML4W Settings App, Quickshell Overview, ML4W
# Dock, Cursors, Fonts, Icons, XDG dirs -- the steps shared with every
# other distro) is run as a separate process, not sourced, so its lack
# of `set -e` isolates its steps from each other and from this
# script's own set -euo pipefail. That matters specifically for the
# ML4W Settings App step: its distro detection doesn't know apt-get
# and exits 1 on Ubuntu, and post.sh has no error handling of its own
# to skip past that -- sourcing it here would abort the whole install
# at that line instead of continuing to Quickshell Overview/Dock/
# Cursors/Fonts/Icons/XDG below it.
run_quiet "Running shared post-install (post.sh)" bash "$repo_path/setup/post.sh"

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
