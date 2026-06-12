# Repo Setup: Variables and Secrets

Each consuming repo needs two Actions **variables** and two Actions
**secrets**. The caller workflows are inert until `DOCS_SSH_DEST` is set, so
you can merge the workflows first and configure deployment later.

| Kind     | Name              | Value                                                          |
|----------|-------------------|----------------------------------------------------------------|
| variable | `DOCS_SSH_DEST`   | `docsuser@docs-host.example.net` (user@host, **no path**)       |
| variable | `DOCS_SITE_URL`   | `https://docs.example.com/<project>` (**no trailing slash**)    |
| secret   | `DOCS_DEPLOY_KEY` | The project's private deploy key (the whole key file)          |
| secret   | `DOCS_HOST_KEY`   | Pinned `known_hosts` line from `ssh-keyscan`                    |

The filesystem path on the host appears in none of these — it lives only in
the server-side rrsync forced command ([server-setup.md](server-setup.md)).

## With the gh CLI

Run from a checkout of the target repo (or add `-R <owner>/<project>`).

The `env -u GH_TOKEN -u GITHUB_TOKEN` prefix matters: if your shell exports
either token variable, `gh` uses it instead of your keychain login, and such
tokens often lack the scopes to write secrets — clearing them makes `gh`
fall back to its stored credentials.

```bash
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set DOCS_DEPLOY_KEY \
    < ~/.ssh/github-deploy-docs-<project>

env -u GH_TOKEN -u GITHUB_TOKEN gh secret set DOCS_HOST_KEY \
    --body "$(ssh-keyscan -t ed25519 docs-host.example.net 2>/dev/null)"

env -u GH_TOKEN -u GITHUB_TOKEN gh variable set DOCS_SSH_DEST \
    --body 'docsuser@docs-host.example.net'

env -u GH_TOKEN -u GITHUB_TOKEN gh variable set DOCS_SITE_URL \
    --body 'https://docs.example.com/<project>'
```

Verify:

```bash
env -u GH_TOKEN -u GITHUB_TOKEN gh variable list
env -u GH_TOKEN -u GITHUB_TOKEN gh secret list
```

## Manually (web UI)

1. Repo → **Settings** → **Secrets and variables** → **Actions**.
2. **Variables** tab → *New repository variable* → add `DOCS_SSH_DEST` and
   `DOCS_SITE_URL` with the values above.
3. **Secrets** tab → *New repository secret*:
   - `DOCS_DEPLOY_KEY`: paste the full contents of
     `~/.ssh/github-deploy-docs-<project>` (the private key, including the
     `-----BEGIN/END-----` lines).
   - `DOCS_HOST_KEY`: paste the one-line output of
     `ssh-keyscan -t ed25519 docs-host.example.net`.

## First deploy

With variables/secrets in place, either push a docs change to a configured
branch or run the workflow manually: repo → **Actions** → *docs (branch
push)* → **Run workflow**. The run should end with an rsync upload; the site
appears at `https://docs.example.com/<project>/main/`.
