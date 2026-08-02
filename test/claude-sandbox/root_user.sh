#!/usr/bin/env bash
#
# A bare debian image with no non-root user: the sudoers drop-in is skipped
# and the firewall runs directly. This is the path most language base images
# (clojure:*, python:*, node:*) land on when common-utils is not also present.

set -e
source dev-container-features-test-lib

check "running as root" bash -c "test \"\$(id -u)\" -eq 0"
check "no sudoers drop-in was written" bash -c "! test -e /etc/sudoers.d/claude-sandbox-firewall"
check "claude installed for root" bash -c "command -v claude && claude --version"
check "utilities were skipped" bash -c "! command -v rg"
check "onboarding seeded" bash -c "jq -e '.hasCompletedOnboarding == true' /claude-state/.claude.json"
check "example.com is blocked" bash -c "! curl -s -m 5 https://example.com >/dev/null"
check "api.anthropic.com is reachable" bash -c "curl -s -m 10 -o /dev/null https://api.anthropic.com/v1/messages"

reportResults
