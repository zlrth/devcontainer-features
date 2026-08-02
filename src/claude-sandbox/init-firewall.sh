#!/usr/bin/env bash
#
# Default-deny egress for a dev container.
#
# Container isolation bounds what an agent can *write*; it does nothing about
# what it can *send*. This script closes that gap: OUTPUT defaults to DROP and
# only the hosts Claude Code and this project actually need are allowed
# through.
#
# Run as root at container start. The claude-sandbox feature wires it to
# postStartCommand rather than postCreateCommand on purpose: iptables rules
# live in the network namespace, which is rebuilt on every restart.
#
# Limitation worth knowing: allowlisting is by resolved IP, captured now. The
# CDNs behind package registries and GitHub rotate addresses, so a container
# left up for days may start seeing dropped connections. Re-run to refresh.

set -euo pipefail

CONF_DIR=/etc/claude-sandbox
SET_NAME=allowed-egress

# Written by the feature's install.sh from the FIREWALL and GITHUB_RANGES
# options. Defaults here keep the script runnable standalone.
FIREWALL=on
GITHUB_RANGES=on
# shellcheck source=/dev/null
[ -r "${CONF_DIR}/sandbox.env" ] && . "${CONF_DIR}/sandbox.env"

if [[ "${FIREWALL}" != "on" ]]; then
    echo "init-firewall: disabled by ${CONF_DIR}/sandbox.env, leaving egress open"
    exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
    echo "init-firewall: must run as root (try: sudo $0)" >&2
    exit 1
fi

# Hosts Claude Code itself talks to. Deliberately short: telemetry rides on
# api.anthropic.com, and the binary carries no separate statsig or sentry
# hostname, so there is nothing else to open up. claude.ai serves the installer
# and artifact publishing; downloads.claude.ai is where the installer and every
# subsequent auto-update actually fetch the binary from, so leaving it out
# gives you an agent that runs but can never update itself.
CLAUDE_DOMAINS=(
    api.anthropic.com
    claude.ai
    downloads.claude.ai
)

# Split a space-, comma-, or newline-separated list into the array named by $1.
# Worth doing explicitly: `read -a` splits on IFS, so a script that sets
# IFS=$'\n\t' for safety silently stops splitting the space-separated lists
# that every one of these variables is documented to accept, and the whole
# string is then handed to dig as a single hostname.
split_into() {
    local -n _out="$1"
    local raw="${2:-}"
    local old_ifs="${IFS}"
    IFS=$' \t\n,'
    # shellcheck disable=SC2206  # word splitting is the point
    _out=( ${raw} )
    IFS="${old_ifs}"
}

# Project domains, from the feature's allowedDomains option and from anything
# a project Dockerfile has dropped into domains.d/ (one domain per line, '#'
# comments allowed).
PROJECT_DOMAINS=()
if [[ -d "${CONF_DIR}/domains.d" ]]; then
    while read -r line; do
        line="${line%%#*}"
        [[ -z "${line// /}" ]] && continue
        split_into _chunk "${line}"
        PROJECT_DOMAINS+=("${_chunk[@]}")
    done < <(cat "${CONF_DIR}"/domains.d/*.conf 2>/dev/null || true)
fi

# Anything extra the caller wants for this run. Reaches us through sudo only
# because the feature's sudoers drop-in adds it to env_keep.
split_into EXTRA_DOMAINS "${EXTRA_ALLOWED_DOMAINS:-}"

echo "init-firewall: resolving allowlist before locking egress down"

# On a user-defined Docker network — which is every docker-compose project, and
# every `docker run --network` — resolv.conf points at Docker's embedded
# resolver on 127.0.0.11, and that address answers only because of DNAT rules
# in the nat table. The flush below removes them, so without this save the
# resolution phase that follows has no DNS at all: every domain logs "no A
# record", the ipset ends up empty, and the run dies on its own verification
# step. Service names (`db`, `redis`) stop resolving for the container's whole
# life too. Captured before the flush, replayed after it.
DOCKER_DNS_RULES="$(iptables-save -t nat | grep '127\.0\.0\.11' || true)"

# Start from a clean slate so re-running is idempotent. Policies must go back
# to ACCEPT *before* the flush: -F removes the ACCEPT rules but keeps the DROP
# policies, and the resolution phase below needs working DNS and HTTPS. The
# refresh therefore opens egress for the second or two it takes to rebuild the
# ruleset — inherent to refreshing by re-run.
iptables -P INPUT  ACCEPT
iptables -P OUTPUT ACCEPT
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy "${SET_NAME}" 2>/dev/null || true
ipset create "${SET_NAME}" hash:net

# Only the 127.0.0.11 rules go back, not the whole nat table: restoring it
# wholesale would also reinstate anything else that had accumulated there. The
# two chains are recreated first because -X deleted them along with the rules
# that referenced them.
if [[ -n "${DOCKER_DNS_RULES}" ]]; then
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "${DOCKER_DNS_RULES}" | xargs -L 1 iptables -t nat
    echo "init-firewall: restored Docker embedded-DNS rules"
fi

# GitHub publishes its ranges, which is more durable than resolving the
# hostnames: git operations land on addresses a single A record never sees.
# Non-fatal, because the explicit hostnames below cover the common paths.
if [[ "${GITHUB_RANGES}" == "on" ]]; then
    if github_meta="$(curl -fsS -m 20 https://api.github.com/meta)"; then
        while read -r cidr; do
            [[ -z "${cidr}" || "${cidr}" == *:* ]] && continue
            ipset add "${SET_NAME}" "${cidr}" 2>/dev/null || true
        done < <(echo "${github_meta}" | jq -r '(.git + .web + .api)[]?')
        echo "init-firewall: added GitHub published ranges"
    else
        echo "init-firewall: WARNING could not fetch api.github.com/meta; relying on resolved hostnames" >&2
    fi
fi

resolve_into_set() {
    local domain="$1" addrs
    addrs="$(dig +short +time=3 +tries=2 A "${domain}" | grep -E '^[0-9.]+$' || true)"
    if [[ -z "${addrs}" ]]; then
        echo "init-firewall: WARNING no A record for ${domain}" >&2
        return 0
    fi
    while read -r ip; do
        [[ -z "${ip}" ]] && continue
        ipset add "${SET_NAME}" "${ip}" 2>/dev/null || true
    done <<< "${addrs}"
    echo "init-firewall: allowed ${domain}"
}

for domain in "${CLAUDE_DOMAINS[@]}" \
              "${PROJECT_DOMAINS[@]:-}" \
              "${EXTRA_DOMAINS[@]:-}"; do
    [[ -z "${domain}" ]] && continue
    resolve_into_set "${domain}"
done

# Loopback covers Docker's embedded DNS resolver at 127.0.0.11, and any
# language server or REPL you start.
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Replies to connections we opened. Without this every allowed request hangs.
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# DNS has to stay open or nothing resolves after the policy flips.
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# The container's own subnet, so the host can reach forwarded ports. iptables
# applies the mask itself, so the address/prefix pair from `ip` goes in as-is.
if subnet="$(ip -o -f inet addr show eth0 2>/dev/null | awk '{print $4}')" && [[ -n "${subnet}" ]]; then
    iptables -A INPUT  -s "${subnet}" -j ACCEPT
    iptables -A OUTPUT -d "${subnet}" -j ACCEPT
    echo "init-firewall: allowed local subnet ${subnet}"
fi

iptables -A OUTPUT -m set --match-set "${SET_NAME}" dst -j ACCEPT

iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

echo "init-firewall: egress now default-deny"

# Verify both directions of the claim, so a silently-broken ruleset does not
# read as a working one. The negative canary is picked from hosts nobody
# allowlisted — asserting example.com is blocked would be wrong for the caller
# who just allowed it.
canary=""
all_domains=" ${CLAUDE_DOMAINS[*]} ${PROJECT_DOMAINS[*]:-} ${EXTRA_DOMAINS[*]:-} "
for candidate in example.com example.net example.org; do
    if [[ "${all_domains}" != *" ${candidate} "* ]]; then
        canary="${candidate}"
        break
    fi
done
if [[ -z "${canary}" ]]; then
    echo "init-firewall: WARNING every canary host is allowlisted; skipping the blocked-egress check" >&2
elif curl -s -m 5 "https://${canary}" >/dev/null 2>&1; then
    echo "init-firewall: FAILED — ${canary} is still reachable" >&2
    exit 1
else
    echo "init-firewall: verified — ${canary} blocked"
fi

# 401 from an unauthenticated GET is a reachable API; only a connection-level
# failure means the rules are wrong.
if ! curl -s -m 10 -o /dev/null https://api.anthropic.com/v1/messages; then
    echo "init-firewall: FAILED — api.anthropic.com is unreachable" >&2
    exit 1
fi
echo "init-firewall: verified — api.anthropic.com reachable"
