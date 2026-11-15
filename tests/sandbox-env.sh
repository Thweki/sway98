#!/usr/bin/env bash
set -euo pipefail

# Both harnesses must reset overrides before running installer or rollback code.
# The caller supplies the test root and the only allowed input: a source tree.
sway98_sandbox_env() {
    local sandbox_dir="$1" theme_src="$2" repo_root="$SWAY98_ROOT" override
    for override in "${!SWAY98_@}"; do
        unset "$override"
    done

    export SWAY98_ROOT="$repo_root"
    export HOME="$sandbox_dir/home"
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_DATA_HOME="$HOME/.local/share"
    export XDG_STATE_HOME="$sandbox_dir/state"
    export XDG_CACHE_HOME="$sandbox_dir/cache"
    export SWAY98_THEME_SRC="$theme_src"
    # gsettings would talk to the developer's real dconf daemon.
    export SWAY98_NO_GSETTINGS=1
    unset SWAYSOCK WAYLAND_DISPLAY
}
