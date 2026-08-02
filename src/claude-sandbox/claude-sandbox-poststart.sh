#!/usr/bin/env bash
#
# postStartCommand for the claude-sandbox feature. Two jobs, in this order:
#
#   1. Make sure Claude Code's state directory answers the first-run wizard,
#      including trusting whatever folder this container was opened on.
#   2. Install the egress rules, which have to happen on every start because
#      the network namespace is rebuilt each time.
#
# Runs as the remote user, from the workspace folder.

set -euo pipefail

CONF_DIR=/etc/claude-sandbox
SEED_ONBOARDING=on
PERMISSION_MODE=acceptEdits
BYPASS_PERMISSIONS=off
THEME=dark
FIREWALL=on
# shellcheck source=/dev/null
[ -r "${CONF_DIR}/sandbox.env" ] && . "${CONF_DIR}/sandbox.env"

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
CONFIG_JSON="${CONFIG_DIR}/.claude.json"

# The wizard runs whenever .claude.json is absent, and it asks you to pick a
# login method *without ever consulting CLAUDE_CODE_OAUTH_TOKEN* — so a
# correctly forwarded token still lands you on a sign-in screen. Seeding the
# file is what turns a --rm run into one that goes straight to the prompt.
#
# Doing it here rather than at build time is what makes the trusted-folder
# entry portable: the workspace path is a runtime fact (it is this script's
# working directory), and baking one repo's path into the image would trust
# the wrong folder in the next repo.
if [[ "${SEED_ONBOARDING}" == "on" ]]; then
    mkdir -p "${CONFIG_DIR}"
    [ -s "${CONFIG_JSON}" ] || echo '{}' > "${CONFIG_JSON}"

    workspace="${PWD}"
    accepted=false
    [[ "${BYPASS_PERMISSIONS}" == "on" ]] && accepted=true

    # Merged rather than overwritten: on the second start this file is the
    # volume's copy, carrying real session state we have no business dropping.
    # Existing keys win, so a theme changed inside the container sticks.
    if tmp="$(mktemp "${CONFIG_DIR}/.claude.json.XXXXXX")" && \
       jq --arg ws "${workspace}" \
          --arg theme "${THEME}" \
          --argjson accepted "${accepted}" \
          '({ hasCompletedOnboarding: true, theme: $theme }
            + (if $accepted then { bypassPermissionsModeAccepted: true } else {} end))
           * .
           | .projects //= {}
           | .projects[$ws] //= {}
           | .projects[$ws].hasTrustDialogAccepted = true' \
          "${CONFIG_JSON}" > "${tmp}"; then
        mv "${tmp}" "${CONFIG_JSON}"
        echo "claude-sandbox: onboarding seeded, ${workspace} trusted"
    else
        rm -f "${tmp:-}"
        echo "claude-sandbox: WARNING could not seed ${CONFIG_JSON}" >&2
    fi

    # The default permission mode lives in settings.json, not .claude.json.
    # Seeding acceptEdits means a plain `claude` auto-approves edits but still
    # asks before running commands — the sandbox makes bypass *defensible*,
    # but it should be a choice, not the default. Existing keys win here too,
    # so a mode changed with /permissions inside the container sticks.
    SETTINGS_JSON="${CONFIG_DIR}/settings.json"
    [ -s "${SETTINGS_JSON}" ] || echo '{}' > "${SETTINGS_JSON}"
    if tmp="$(mktemp "${CONFIG_DIR}/settings.json.XXXXXX")" && \
       jq --arg mode "${PERMISSION_MODE}" \
          '{ permissions: { defaultMode: $mode } } * .' \
          "${SETTINGS_JSON}" > "${tmp}"; then
        mv "${tmp}" "${SETTINGS_JSON}"
        echo "claude-sandbox: default permission mode is ${PERMISSION_MODE}"
    else
        rm -f "${tmp:-}"
        echo "claude-sandbox: WARNING could not seed ${SETTINGS_JSON}" >&2
    fi
fi

if [[ "${FIREWALL}" != "on" ]]; then
    echo "claude-sandbox: firewall disabled, egress left open"
    exit 0
fi

# sudo is scoped to this one script, deliberately: an agent with blanket sudo
# can flush the egress rules, which would defeat the point of having them.
if [[ "${EUID}" -eq 0 ]]; then
    exec /usr/local/bin/init-firewall.sh
else
    exec sudo -n /usr/local/bin/init-firewall.sh
fi
