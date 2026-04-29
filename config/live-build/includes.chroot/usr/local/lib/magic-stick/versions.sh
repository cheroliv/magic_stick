#!/bin/sh
# Centralisation des versions des outils externes
# Sourcer avec : . /usr/local/lib/magic-stick/versions.sh
#
# Conventions:
# - Les variables contiennent EXACTEMENT le tag GitHub (v si prefixe, sinon non).
# - Les variables *_ARCH sont calculees par get_arch_suffix() (cf arch.sh).
# - "latest" est interdit pour les binaires critiques (reproductibilite).

# === Package managers ===
UV_VERSION="0.11.8"
NVM_VERSION="v0.40.4"
PNPM_VERSION="10.33.2"

# === Binaires GitHub Releases (pinning reproductible) ===
RIPGREP_VERSION="14.1.1"
FD_VERSION="v10.2.0"
LAZYGIT_VERSION="v0.61.1"
JUST_VERSION="1.50.0"
XH_VERSION="v0.25.3"
OPENCODE_VERSION="0.0.55"
GHCLI_VERSION="v2.92.0"
FZF_VERSION="v0.72.0"

# === Autres ===
JETBRAINS_TOOLBOX_VERSION="3.4.3.81140"
VSCODE_VERSION="latest"        # VS Code n'a pas de releases versionnees sur GitHub
SDKMAN_VERSION="latest"        # SDKMAN n'a pas de versioning fixe
STARSHIP_VERSION="latest"      # starship.rs/install.sh ne permet pas de version fixe facile
