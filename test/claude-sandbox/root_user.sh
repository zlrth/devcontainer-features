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

# Docker's embedded resolver lives at 127.0.0.11 and answers only because of
# DNAT rules in the nat table, which the firewall flushes. The test harness
# runs on the default bridge, which has no such rules, so they are staged here
# by hand: what matters is that a nat rule naming 127.0.0.11 survives a run.
# Without the save/restore, a compose project loses DNS mid-script — every
# domain fails to resolve and the run dies on its own verification step.
#
# This is the only scenario running as root, hence the only one that can touch
# iptables at all: elsewhere the sudoers scoping deliberately forbids it.
iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
iptables -t nat -A DOCKER_OUTPUT -d 127.0.0.11/32 -p udp -m udp --dport 53 \
    -j DNAT --to-destination 127.0.0.11:44778
/usr/local/bin/init-firewall.sh >/dev/null

check "Docker embedded-DNS nat rules survive the flush" \
    bash -c "iptables-save -t nat | grep -q '127\.0\.0\.11'"

reportResults
