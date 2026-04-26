# Hanasand Git Server

### How to run
1. Add a `.env` file with `DB_PASSWD`
2. Run `docker compose up --build`

### Actions runner
Forgejo Actions are enabled in the `git` service. The bundled `runner` service can execute Linux/container jobs after it is registered.

Add this to `.env` after creating a runner registration token in Forgejo:

```env
GITEA_RUNNER_REGISTRATION_TOKEN=...
GITEA_RUNNER_NAME=git-runner
GITEA_RUNNER_LABELS=docker:docker://node:22-bookworm
```

The Hanasand desktop app update workflow needs a macOS runner because SwiftUI `.app` bundles cannot be built inside the Linux git container. Register a macOS runner with the `macos` label for `.forgejo/workflows/desktop-app-update.yml`.
