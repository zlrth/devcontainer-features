# devcontainer-features

Dev container [Features](https://containers.dev/implementors/features/),
published to `ghcr.io/zlrth/devcontainer-features/<id>`.

| Feature | What it is |
| --- | --- |
| [`claude-sandbox`](src/claude-sandbox) | Claude Code + default-deny egress firewall + persistent auth/state, so running the agent unattended has a bounded blast radius |

## Using a feature

```jsonc
{
  "image": "mcr.microsoft.com/devcontainers/base:bookworm",
  "features": {
    "ghcr.io/zlrth/devcontainer-features/claude-sandbox:1": {}
  }
}
```

## Developing

Tests run with the [dev container CLI](https://github.com/devcontainers/cli):

```bash
npx @devcontainers/cli features test -f claude-sandbox \
  --base-image mcr.microsoft.com/devcontainers/base:bookworm .
```

`test/<feature>/test.sh` covers the defaults; `scenarios.json` covers the
options (firewall off, extra domains + bypass mode, bare-root images).

Pushing to `main` with changes under `src/` publishes via
`.github/workflows/release.yaml`. Versions come from each feature's
`devcontainer-feature.json`; bump `version` there to release.
