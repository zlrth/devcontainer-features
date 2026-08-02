#!/usr/bin/env bash
#
# The opt-in flavor: extra domains allowlisted, bypass mode chosen and its
# warning pre-accepted, blanket sudo deliberately retained (restrictSudo:
# false), GitHub ranges off.

set -e
source dev-container-features-test-lib

check "option written to the drop-in dir" \
    bash -c "grep -qx 'example.com' /etc/claude-sandbox/domains.d/10-feature-options.conf"
check "comma-separated entries were split" \
    bash -c "grep -qx 'repo.clojars.org' /etc/claude-sandbox/domains.d/10-feature-options.conf"

# example.com is the host the default scenario asserts is blocked; allowing it
# here is what proves the option reaches the ruleset rather than the script
# merely reading the file.
check "an allowlisted domain is reachable" bash -c "curl -s -m 10 -o /dev/null https://example.com"
check "a domain nobody allowed is not" bash -c "! curl -s -m 5 https://www.iana.org >/dev/null"

check "githubRanges: false is honoured" bash -c "grep -q '^GITHUB_RANGES=off' /etc/claude-sandbox/sandbox.env"

check "chosen permission mode is seeded" \
    bash -c "jq -e '.permissions.defaultMode == \"bypassPermissions\"' /claude-state/settings.json"
check "bypass warning pre-accepted when opted in" \
    bash -c "jq -e '.bypassPermissionsModeAccepted == true' /claude-state/.claude.json"
check "theme is seeded" bash -c "jq -e '.theme == \"light\"' /claude-state/.claude.json"

# restrictSudo: false keeps the base image's NOPASSWD:ALL. Whether that is
# wise is the consumer's call; this asserts the knob works.
check "blanket sudo retained when restrictSudo is false" bash -c "sudo -n /bin/true"

reportResults
