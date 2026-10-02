#!/usr/bin/env bash

mkdir -p "$HOME/.local/bin"

# --------------------------------------------------------------
# Repositories
# --------------------------------------------------------------

# trixie-backports -- official Debian infrastructure, uses the system's
# existing signing keys (no separate keyring like a PPA needs). Hyprland,
# quickshell, and the rest of the ecosystem below are packaged here by
# the Debian Hyprland Maintainers team, not in trixie main.
# Match only an active `deb` line, not a commented-out one -- Debian's
# own installer commonly leaves a commented trixie-backports suggestion
# in /etc/apt/sources.list by default, which a bare substring grep would
# treat as "already present" and never actually enable.
if ! grep -Rq "^deb .*trixie-backports" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    info "Adding trixie-backports"
    echo "deb http://deb.debian.org/debian trixie-backports main" |
        sudo tee /etc/apt/sources.list.d/trixie-backports.list > /dev/null
else
    info "trixie-backports already present"
fi

# gum (not in Debian main). -s, not -f: a failed curl leaves a 0-byte
# keyring that -f would treat as present.
if [ ! -s /etc/apt/keyrings/charm.gpg ]; then
    info "Adding Charm apt repo for gum"
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list > /dev/null
else
    info "Charm apt repo already present"
fi

sudo apt-get update

if ! command -v gum &> /dev/null; then
    sudo apt-get install -y gum
fi

# --------------------------------------------------------------
# Hyprland + quickshell ecosystem -- trixie-backports only, so these need
# explicit -t targeting. A plain `apt-get install` (as the shared
# packages/packages-debian lists do) ignores backports by default even
# once the suite is added, since backports packages carry a lower
# priority on purpose.
#
# Unlike the best-effort packages/packages-debian loop (one failure
# logged and skipped, install continues), this is a single atomic
# transaction with no per-package fallback: every one of these is
# load-bearing for the rest of the install (building matugen/awww/
# grimblast assumes a working Hyprland session exists to configure,
# and quickshell is what the whole ML4W shell is built on) -- failing
# fast here and aborting the run is correct, not an oversight.
# --------------------------------------------------------------

sudo apt-get install -y -t trixie-backports \
    hyprland \
    hypridle \
    hyprlock \
    hyprpaper \
    hyprpicker \
    hyprpolkitagent \
    hyprsunset \
    xdg-desktop-portal-hyprland \
    quickshell

# --------------------------------------------------------------
# Uninstall swww if exists. To be replaced with awww in the next steps
# --------------------------------------------------------------

if dpkg -l 2>/dev/null | grep -q "^ii  swww "; then
    sudo apt-get remove -y swww
fi
