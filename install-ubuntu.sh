#!/usr/bin/env bash

# Ubuntu 26.04 installer for ML4W OS -- local testing scaffold.
#
# The real installer (bash <(curl -s https://ml4w.com/os/rolling)) clones
# github.com/mylinuxforwork/ml4w-dotfiles-installer, whose distro detection
# (get_distro_by_bin in lib/helpers.sh) only recognizes pacman/dnf/zypper
# and hard-exits on anything else -- Ubuntu is not reachable through it
# today. This script replicates the same setup/preflight -> packages ->
# setup/post dispatch (see run_setup_logic in that repo's lib/utils.sh) so
# this repo's Ubuntu support can be exercised end to end without waiting on
# a companion change there.
#
# Known, deliberate differences from the real installer:
#   - Deployment here is a flat `rsync -av dotfiles/ $HOME/` copy. The real
#     installer stages into ~/.mydotfiles/<profile_id>/ and symlinks each
#     top-level entry (and each .config child) into $HOME instead. Fine for
#     exercising package installs and post-install scripts, but anything
#     that assumes it's reached through a symlink (e.g. migration.sh's
#     `[ -L $NVIM_DIR ]` check) won't behave identically under this script.
#   - Restore handling here is unconditional (back up and restore every
#     dotinst restore-manifest entry). The real installer is interactive
#     (`gum choose --no-limit`, user picks which entries to keep).
#   - The real installer also shows an interactive `gum confirm` profile
#     summary before doing anything; this script has none.
#   - Package installs here are best-effort: a failed `apt-get install` is
#     logged to ~/.ml4w-missing-packages.log and the loop continues rather
#     than aborting, matching how ml4w-dotfiles-installer's
#     process_package_file() behaves (it doesn't abort on a single failed
#     install either).

set -e

repo_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export repo_path

# Provide the info/warn/error helpers that setup/*.sh scripts expect from
# the real installer framework (see ml4w-dotfiles-installer/lib/colors.sh).
info() { echo -e "\033[0;32m[INFO]\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*" >&2; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }
export -f info warn error

dotinst_file="$repo_path/hyprland-dotfiles.dotinst"
backup_dir="$HOME/.ml4w-backup-$(date +%Y%m%d-%H%M%S)"

# Noisy command output (apt-get, cargo, cmake/ninja, go build, etc.) goes
# here instead of the terminal. `gum spin` (installed by preflight-ubuntu.sh)
# shows a spinner and only prints a wrapped command's output if it fails.
LOG_FILE="$HOME/.ml4w-install.log"
: > "$LOG_FILE"
export LOG_FILE

run_quiet() {
    local title=$1; shift
    echo "=== $title ===" >> "$LOG_FILE"
    # Always tee into LOG_FILE, not just show-on-failure -- gum's own
    # --show-error only prints to the terminal for a failed step and
    # doesn't persist anything, so a compile failure scrolled past (or a
    # step that succeeds but is worth checking later) left no record.
    if ! gum spin --title "$title" --show-error -- bash -c '
        set -o pipefail
        "$@" 2>&1 | tee -a "$LOG_FILE"
    ' _ "$@"; then
        error "$title -- failed (see $LOG_FILE)"
        return 1
    fi
}
export -f run_quiet

# A long install can easily outlast sudo's credential cache (typically
# 15 min), and a password re-prompt inside a `gum spin`-wrapped step would
# be invisible -- indistinguishable from a genuine hang. Keep the sudo
# timestamp alive for the whole run instead. Requires the initial `sudo -v`
# below to succeed interactively before any spinner starts.
sudo -v
( while kill -0 $$ 2>/dev/null; do sudo -n true; sleep 60; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT

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
# gum isn't installed yet at this point in a fresh run, so this step is
# quieted with plain log redirection rather than `gum spin`.
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
    # One spinner for the whole file rather than one per package (this list
    # can run past 80 entries) -- per-package failures still get logged to
    # MISSING_LOG and reported via the summary warn below, they're just not
    # printed live anymore.
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

run_quiet "Deploying dotfiles from $repo_path/dotfiles/" \
    rsync -a "$repo_path/dotfiles/" "$HOME/"

# The real installer always creates ~/.mydotfiles/<profile_id>/ as part of
# its stage-then-symlink deployment (see the header comment above) -- this
# harness's flat rsync doesn't, but autostart.lua unconditionally redirects
# ml4w-autostart's output to ~/.mydotfiles/ml4w-autostart.log. Bash can't
# create a file under a missing parent directory, so without this the
# whole `ml4w-autostart > ~/.mydotfiles/ml4w-autostart.log 2>&1` command
# fails before ml4w-autostart ever runs -- silently, no log, and nothing
# it launches (including quickshell) ever starts. Confirmed live.
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
