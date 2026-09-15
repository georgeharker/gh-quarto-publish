# gh-quarto-publish

A reusable GitHub Actions workflow that renders a repo's markdown docs as a
[Quarto](https://quarto.org) website and publishes it to a plain web host
over rsync — no GitHub Pages, no tokens with repo write access, and a deploy
key that can only write one directory on the server.

Each consuming repo carries only two thin caller workflows; the pipeline —
docs link checking, zero-warning Quarto render, hardened rsync upload —
lives here and is shared by every project.


## Quickstart

1. **Once per web host** — [docs/server-setup.md](docs/server-setup.md):
   rrsync confinement, deploy keys, `.htaccess`.
2. **Per repo** — run `scripts/setup-docs-automation.zsh <project>` (from the
   consuming repo): mints the deploy key, sets the repo secret + variables,
   and installs the server-side authorized_keys line. See
   [docs/repo-setup.md](docs/repo-setup.md).
3. **Copy the templates** — [templates/](templates/): two thin caller
   workflows, `_quarto.yml`, `index.md`. Commit, push.
4. First green run publishes to `https://<site-url>/<branch>/` — and now also
   verifies the deployed root and social-preview image resolve.

File-by-file details: [docs/integration.md](docs/integration.md).

## How it works

```
push to main/dev, or release tag
        │
        ▼
caller workflow (in the consumer repo, ~25 lines)
        │  uses: georgeharker/gh-quarto-publish/.github/workflows/publish.yml
        ▼
publish.yml (this repo)
        ├─ check-docs harness: links, anchors, render-list reachability
        ├─ quarto render        (fails on any warning)
        └─ rsync _site/ → docsuser@host:/<branch>/
                                │ confined by a server-side rrsync
                                ▼ forced command, write-only
        https://docs.example.com/<project>/<branch>/
```

Security properties:

- The deploy key is **per-project** and **write-only**, confined by an
  [rrsync](https://github.com/RsyncProject/rsync/blob/master/support/rrsync)
  forced command with `restrict` — a leaked key can overwrite one project's
  published docs and nothing else.
- The host key is **pinned** (`StrictHostKeyChecking=yes` against a stored
  `known_hosts` line), and the private key is loaded into an ephemeral
  ssh-agent from stdin — it never touches the runner's filesystem.
- No server path appears on the GitHub side; the filesystem root lives only
  in the server-side forced command.

## Documentation

| Step | Document |
|------|----------|
| Prepare the web host (rrsync, deploy keys, `.htaccess`) | [docs/server-setup.md](docs/server-setup.md) |
| Configure a repo's variables and secrets (`gh` or web UI) | [docs/repo-setup.md](docs/repo-setup.md) |
| Wire a repo up (workflows, `_quarto.yml`, `index.md`, README backlink) | [docs/integration.md](docs/integration.md) |

Copy-paste starting points for all consumer-repo files are in
[templates/](templates/).

## Repository contents

```
.github/workflows/publish.yml      # the reusable workflow (workflow_call)
scripts/check-docs.zsh             # shared docs harness, run by the workflow
scripts/setup-docs-automation.zsh  # one-shot per-project provisioning helper
templates/                         # caller workflows, _quarto.yml, index.md
docs/                              # setup and integration guides
```

## Quick integration checklist

1. Host: project docroot + rrsync forced-command key + `.htaccess`
   ([server-setup.md](docs/server-setup.md))
2. Repo files: caller workflows, `_quarto.yml`, `index.md`, `.gitignore`
   entries, README backlink ([integration.md](docs/integration.md))
3. Repo settings: `DOCS_SSH_DEST`, `DOCS_SITE_URL` variables;
   `DOCS_DEPLOY_KEY`, `DOCS_HOST_KEY` secrets
   ([repo-setup.md](docs/repo-setup.md))
4. Push a docs change (or run *docs (branch push)* manually) and check
   `https://docs.example.com/<project>/main/`.

Steps 1 and 3 (the deploy key, repo secrets/variables, and the host's
docroot + forced-command authorized_keys line) can be done in one shot with
`scripts/setup-docs-automation.zsh` — see [repo-setup.md](docs/repo-setup.md).
