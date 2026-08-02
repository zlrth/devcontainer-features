#!/usr/bin/env bash
#
# claude-sandbox feature installer. Runs as root at image build time.
#
# Everything project-specific is a feature option; everything here is the part
# that is the same whatever the toolchain is.

set -euo pipefail

FIREWALL="${FIREWALL:-true}"
ALLOWED_DOMAINS="${ALLOWEDDOMAINS:-}"
GITHUB_RANGES="${GITHUBRANGES:-true}"
INSTALL_CLAUDE_CODE="${INSTALLCLAUDECODE:-true}"
CLAUDE_VERSION="${VERSION:-stable}"
INSTALL_UTILITIES="${INSTALLUTILITIES:-true}"
SEED_ONBOARDING="${SEEDONBOARDING:-true}"
PERMISSION_MODE="${PERMISSIONMODE:-acceptEdits}"
ACCEPT_BYPASS="${ACCEPTBYPASSPERMISSIONS:-false}"
RESTRICT_SUDO="${RESTRICTSUDO:-true}"
THEME="${THEME:-dark}"

USERNAME="${_REMOTE_USER:-root}"
USER_HOME="${_REMOTE_USER_HOME:-$(getent passwd "${USERNAME}" | cut -d: -f6)}"
USER_HOME="${USER_HOME:-/root}"
CONF_DIR=/etc/claude-sandbox
STATE_DIR=/claude-state

FEATURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID}" -ne 0 ]]; then
    echo "claude-sandbox: this feature must be installed as root" >&2
    exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
    echo "claude-sandbox: only Debian/Ubuntu base images are supported (no apt-get found)." >&2
    echo "claude-sandbox: the firewall depends on iptables + ipset, which this installer" >&2
    echo "claude-sandbox: only knows how to fetch with apt." >&2
    exit 1
fi

on() { [[ "$1" == "true" ]] && echo on || echo off; }

# ---------------------------------------------------------------- packages --
# iptables/ipset back init-firewall.sh; dnsutils gives it dig, jq gives it the
# GitHub ranges; iproute2 gives it the container's own subnet.
PACKAGES=(ca-certificates curl dnsutils iproute2 ipset iptables jq sudo)

# What Claude Code reaches for rather than shelling out — ripgrep above all.
[[ "${INSTALL_UTILITIES}" == "true" ]] && PACKAGES+=(git less procps ripgrep unzip)

echo "claude-sandbox: installing ${PACKAGES[*]}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends "${PACKAGES[@]}"
rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------ config --
mkdir -p "${CONF_DIR}/domains.d"

cat > "${CONF_DIR}/sandbox.env" <<EOF
# Written by the claude-sandbox devcontainer feature. Values come from the
# feature's options; edit here to change them without a rebuild.
FIREWALL=$(on "${FIREWALL}")
GITHUB_RANGES=$(on "${GITHUB_RANGES}")
SEED_ONBOARDING=$(on "${SEED_ONBOARDING}")
PERMISSION_MODE=${PERMISSION_MODE}
BYPASS_PERMISSIONS=$(on "${ACCEPT_BYPASS}")
THEME=${THEME}
EOF

# The allowlist is a drop-in directory rather than a single file so that a
# project Dockerfile can COPY its own .conf in alongside this one without
# having to restate the options.
if [[ -n "${ALLOWED_DOMAINS// /}" ]]; then
    {
        echo "# From the claude-sandbox feature's allowedDomains option."
        tr ', ' '\n\n' <<< "${ALLOWED_DOMAINS}" | sed '/^$/d'
    } > "${CONF_DIR}/domains.d/10-feature-options.conf"
    echo "claude-sandbox: allowlisting ${ALLOWED_DOMAINS}"
fi

install -m 0755 "${FEATURE_DIR}/init-firewall.sh" /usr/local/bin/init-firewall.sh
install -m 0755 "${FEATURE_DIR}/claude-sandbox-poststart.sh" /usr/local/bin/claude-sandbox-poststart

# Whether a named volume seeded from an empty image directory inherits that
# directory's ownership varies by Docker daemon: Docker Desktop preserves it,
# the daemon on GitHub's runners leaves the volume root-owned. This helper
# lets the poststart repair the ownership without widening sudo: the target
# and owner are baked in here at build time, so there is nothing for a caller
# to smuggle in.
printf '%s\n' \
    '#!/bin/bash' \
    "exec chown -R ${USERNAME} ${STATE_DIR}" \
    > /usr/local/bin/claude-sandbox-own-state
chmod 0755 /usr/local/bin/claude-sandbox-own-state

# ----------------------------------------------------------------- sudoers --
# The firewall is the one thing that needs root, and it is the only thing this
# entry grants. Deliberately not blanket NOPASSWD: an agent that can sudo
# freely can flush the egress rules, which is the whole point of them.
#
# EXTRA_ALLOWED_DOMAINS needs env_keep to reach the script: sudo's env_reset
# drops it otherwise, and `sudo -E` is refused without SETENV. env_keep is the
# narrower of the two — it preserves that one variable rather than handing the
# caller the whole environment.
if [[ "${USERNAME}" != "root" ]]; then
    printf '%s\n' \
        'Defaults env_keep += "EXTRA_ALLOWED_DOMAINS"' \
        "${USERNAME} ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" \
        "${USERNAME} ALL=(root) NOPASSWD: /usr/local/bin/claude-sandbox-own-state" \
        > /etc/sudoers.d/claude-sandbox-firewall
    chmod 0440 /etc/sudoers.d/claude-sandbox-firewall
    visudo -cf /etc/sudoers.d/claude-sandbox-firewall >/dev/null
    echo "claude-sandbox: ${USERNAME} may sudo init-firewall.sh"

    # The scoped entry above is worthless while a broader one exists: the
    # devcontainers/base images (and the common-utils feature) give the remote
    # user NOPASSWD:ALL, and an agent with that can flush the egress rules.
    # Every sudoers.d file granting NOPASSWD beyond ours goes; a dev container
    # has one human user, so there is no second audience to preserve grants
    # for.
    if [[ "${RESTRICT_SUDO}" == "true" ]]; then
        for f in /etc/sudoers.d/*; do
            [[ -f "${f}" ]] || continue
            [[ "${f##*/}" == "claude-sandbox-firewall" ]] && continue
            if grep -q 'NOPASSWD' "${f}"; then
                rm -f "${f}"
                echo "claude-sandbox: removed blanket sudo grant ${f}"
            fi
        done
        # The main sudoers file is not ours to rewrite; a NOPASSWD in it is
        # rare enough that surfacing it beats silently editing it.
        if grep -q 'NOPASSWD' /etc/sudoers 2>/dev/null; then
            echo "claude-sandbox: WARNING /etc/sudoers itself contains NOPASSWD grants; the firewall is not tamper-proof" >&2
        fi
    fi
fi

# ------------------------------------------------------------------- state --
# Created here, before its volume is attached, so that Docker seeds the named
# volume from an image path already owned by ${USERNAME}. A mount point missing
# from the image gets a root-owned volume instead, and every write the agent
# makes to it then fails.
mkdir -p "${STATE_DIR}"
chown -R "${USERNAME}" "${STATE_DIR}"

# ------------------------------------------------------------ claude code --
if [[ "${INSTALL_CLAUDE_CODE}" == "true" ]]; then
    echo "claude-sandbox: installing Claude Code (${CLAUDE_VERSION})"

    # The native installer. No Node runtime is involved. It puts everything
    # under $HOME, so it has to run as the remote user rather than as root —
    # and CLAUDE_CONFIG_DIR is set here as well as at runtime so that anything
    # it writes lands in the directory the state volume will cover.
    # shellcheck disable=SC2016  # $CLAUDE_VERSION is expanded deliberately
    install_cmd="export CLAUDE_CONFIG_DIR=${STATE_DIR}; curl -fsSL https://claude.ai/install.sh | bash -s -- ${CLAUDE_VERSION}"

    if [[ "${USERNAME}" == "root" ]]; then
        bash -c "${install_cmd}"
    else
        # -s because a base image's user may have been created with nologin;
        # the installer needs a real shell whatever the login policy is.
        su -s /bin/bash - "${USERNAME}" -c "${install_cmd}"
    fi

    # The launcher lands in ~/.local/bin, which is on nobody's PATH by default
    # in a non-login shell — including the one every lifecycle command and
    # `docker exec` runs in. A symlink is more robust here than an ENV PATH,
    # which a feature cannot compose with the remote user's home path anyway.
    if [[ -x "${USER_HOME}/.local/bin/claude" ]]; then
        ln -sf "${USER_HOME}/.local/bin/claude" /usr/local/bin/claude
        echo "claude-sandbox: linked /usr/local/bin/claude -> ${USER_HOME}/.local/bin/claude"
    else
        echo "claude-sandbox: WARNING installer left no ${USER_HOME}/.local/bin/claude" >&2
    fi

    chown -R "${USERNAME}" "${STATE_DIR}"
fi

echo "claude-sandbox: done"
