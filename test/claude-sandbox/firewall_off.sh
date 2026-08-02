#!/usr/bin/env bash
#
# firewall: false — Claude Code is still installed and onboarded, but egress
# is left open. Verifies the opt-out actually opts out rather than half-
# applying a ruleset.

set -e
source dev-container-features-test-lib

check "claude still installed" bash -c "command -v claude"
check "onboarding still seeded" bash -c "jq -e '.hasCompletedOnboarding == true' /claude-state/.claude.json"
check "egress is open" bash -c "curl -s -m 10 -o /dev/null https://example.com"
check "firewall disabled in config" bash -c "grep -q '^FIREWALL=off' /etc/claude-sandbox/sandbox.env"
check "running it anyway is a no-op" bash -c "sudo -n /usr/local/bin/init-firewall.sh | grep -q 'leaving egress open'"

reportResults
