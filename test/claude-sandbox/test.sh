#!/usr/bin/env bash
#
# Default options: firewall on, Claude Code installed, onboarding seeded.
# Runs as the (non-root) remote user, which is why nothing here inspects
# iptables directly — the point of the sudoers scoping is that it can't.

set -e
source dev-container-features-test-lib

check "claude on PATH" bash -c "command -v claude"
check "claude runs" bash -c "claude --version"

check "firewall script installed" bash -c "test -x /usr/local/bin/init-firewall.sh"
check "poststart installed" bash -c "test -x /usr/local/bin/claude-sandbox-poststart"

check "sudo is scoped to the firewall alone" bash -c "! sudo -n /bin/true 2>/dev/null"
check "sudo does grant the firewall" bash -c "sudo -n /usr/local/bin/init-firewall.sh"

check "CLAUDE_CONFIG_DIR points at the state volume" bash -c "test \"\$CLAUDE_CONFIG_DIR\" = /claude-state"
check "state dir is writable by the remote user" bash -c "test -w /claude-state"

# postStartCommand should have seeded onboarding and trusted this folder.
check "onboarding seeded" bash -c "jq -e '.hasCompletedOnboarding == true' /claude-state/.claude.json"
check "workspace folder trusted" bash -c "jq -e --arg ws \"\$PWD\" '.projects[\$ws].hasTrustDialogAccepted == true' /claude-state/.claude.json"

# The default is auto-accept-edits, not bypass: bypass stays a per-project
# opt-in, so its warning must NOT be pre-accepted here.
check "default permission mode is acceptEdits" \
    bash -c "jq -e '.permissions.defaultMode == \"acceptEdits\"' /claude-state/settings.json"
check "bypass-permissions warning not pre-accepted" \
    bash -c "jq -e '.bypassPermissionsModeAccepted == null' /claude-state/.claude.json"

# The firewall, asserted behaviourally from outside the script that installs
# it, so a regression in its own verification cannot hide a broken ruleset.
check "example.com is blocked" bash -c "! curl -s -m 5 https://example.com >/dev/null"
check "api.anthropic.com is reachable" bash -c "curl -s -m 10 -o /dev/null https://api.anthropic.com/v1/messages"
check "downloads.claude.ai is reachable, so the agent can update itself" \
    bash -c "curl -s -m 10 -o /dev/null https://downloads.claude.ai/claude-code-releases/latest"
check "github is reachable via the published ranges" \
    bash -c "curl -s -m 15 -o /dev/null https://api.github.com/meta"

reportResults
