# gh-quarto-publish

A reusable GitHub Actions workflow that renders a repo's markdown docs as a
[Quarto](https://quarto.org) website and publishes it to a plain web host
over rsync — no GitHub Pages, no tokens with repo write access, and a deploy
key that can only write one directory on the server.

Each consuming repo carries only two thin caller workflows; the pipeline —
docs link checking, zero-warning Quarto render, hardened rsync upload —
lives here and is shared by every project.

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
.github/workflows/publish.yml   # the reusable workflow (workflow_call)
scripts/check-docs.zsh          # shared docs harness, run by the workflow
templates/                      # caller workflows, _quarto.yml, index.md
docs/                           # setup and integration guides
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
