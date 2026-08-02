# claude-sandbox

A [dev container Feature](https://containers.dev/implementors/features/) that
turns any Debian/Ubuntu-based dev container into a bounded sandbox for running
Claude Code unattended: the filesystem is contained by the container, egress is
contained by a default-deny firewall, and the agent's auth and state survive
`--rm` runs.

```jsonc
// .devcontainer/devcontainer.json
{
  "image": "mcr.microsoft.com/devcontainers/base:bookworm",
  "features": {
    "ghcr.io/zlrth/devcontainer-features/claude-sandbox:1": {
      "allowedDomains": "registry.npmjs.org"   // your toolchain's hosts
    }
  },
  "containerEnv": {
    "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}"
  }
}
```

Authenticate on the host first — `claude setup-token`, then export
`CLAUDE_CODE_OAUTH_TOKEN`. Mounting `~/.claude` is not a substitute: on macOS
the OAuth credentials live in the Keychain, not in that directory.

The default permission mode seeded into the container is **acceptEdits** —
edits are auto-approved, commands still ask. The sandbox is what makes
`bypassPermissions` *defensible*; it is deliberately not the default. To opt
in: `"permissionMode": "bypassPermissions", "acceptBypassPermissions": true`.

## What it protects, and what it doesn't

- **Writes** are bounded by the container. On macOS Docker is a VM, so this is
  kernel-level isolation, not a seatbelt profile.
- **Egress** is bounded by `init-firewall.sh`: `OUTPUT` defaults to DROP, and
  only Anthropic's hosts, GitHub's published ranges, and the domains you list
  are allowed. The script verifies both directions before it exits — that a
  canary host is blocked *and* that `api.anthropic.com` is reachable — so a
  silently-broken ruleset can't read as a working one.
- **sudo** is scoped to the firewall script alone, and blanket `NOPASSWD`
  grants from the base image are removed (`restrictSudo`), because an agent
  that can `sudo iptables -F` is not sandboxed.

Not protected:

- **Your working tree.** The workspace is a bind mount of the real repo, so an
  `rm -rf` in there is an `rm -rf` on your disk. Commit or push before an
  unattended run, or mount a throwaway clone.
- **Anything you allowlist.** Opening a domain opens it for everything in the
  container.

## Options

| Option | Default | What it does |
| --- | --- | --- |
| `firewall` | `true` | Lock egress down at container start |
| `allowedDomains` | `""` | Extra domains, space- or comma-separated |
| `githubRanges` | `true` | Allow GitHub's published IP ranges from `api.github.com/meta` |
| `installClaudeCode` | `true` | Install Claude Code (native installer, no Node) |
| `version` | `stable` | `stable`, `latest`, or exact `x.y.z` |
| `installUtilities` | `true` | ripgrep, git, jq, less, procps, unzip |
| `seedOnboarding` | `true` | Skip the first-run wizard; trust the workspace folder |
| `permissionMode` | `acceptEdits` | Default mode seeded into `settings.json` |
| `acceptBypassPermissions` | `false` | Pre-accept the bypass-permissions warning |
| `restrictSudo` | `true` | Remove the base image's blanket `NOPASSWD` sudo grants |
| `theme` | `dark` | Claude Code theme to seed |

## How the pieces fit

- **`/claude-state`** — a named volume, per devcontainer, holding Claude
  Code's state. `CLAUDE_CONFIG_DIR` points at it, which is what makes auth
  stick: the first-run wizard runs whenever `.claude.json` is absent, and by
  default that file lives at the home root — *outside* any state volume — so
  every `--rm` run would reopen it. The wizard never consults
  `CLAUDE_CODE_OAUTH_TOKEN`, so a correctly-forwarded token still lands on a
  sign-in screen without this.
- **`postStartCommand`** — seeds onboarding (including trusting the workspace
  folder, a runtime fact that can't be baked into an image) and installs the
  firewall. Start rather than create because iptables rules live in the
  network namespace, which is rebuilt on every restart.
- **`/etc/claude-sandbox/domains.d/*.conf`** — the allowlist as a drop-in
  directory. `allowedDomains` writes one file; a project Dockerfile can COPY
  more alongside it, one domain per line, `#` comments allowed.
- **For one session only**: `EXTRA_ALLOWED_DOMAINS="a.example b.example" sudo
  init-firewall.sh` — the sudoers entry `env_keep`s exactly that variable.

## Limitations worth knowing

- Allowlisting is **by resolved IP, captured at start**. CDNs rotate, so a
  container left up for days may see drops. Re-run
  `sudo /usr/local/bin/init-firewall.sh` to refresh (egress is open for the
  second or two the rebuild takes).
- Debian/Ubuntu bases only — the installer fetches iptables/ipset with apt.
- The container needs `NET_ADMIN` and `NET_RAW` (the feature declares them)
  and must **not** run with `--cap-drop=ALL`: sudo needs SETUID/SETGID, and
  dropping them takes the firewall with it.

## Troubleshooting

**It asks me to log in anyway.** Check the token actually crossed the
boundary: `-e VAR` with no value forwards nothing when `VAR` is set but not
exported. A token that arrives but is wrong fails loudly instead — headless
mode says `401 OAuth access token is invalid`. A Console API key
(`sk-ant-api03-…`) is not an OAuth token (`sk-ant-oat01-…`); the key belongs in
`ANTHROPIC_API_KEY`, and only `claude setup-token` produces the other.

**I want to `/login` from inside the container.** The default allowlist doesn't
cover the OAuth endpoints, on the principle that the token is the supported
path in here. For a session:

```bash
EXTRA_ALLOWED_DOMAINS="claude.com platform.claude.com" \
  sudo /usr/local/bin/init-firewall.sh
```
