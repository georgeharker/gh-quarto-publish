# Integrating a Repo

What a consuming repo needs, file by file. Templates for everything live in
[../templates/](../templates/).

## 1. Caller workflows

Copy [templates/docs-on-change.yml](../templates/docs-on-change.yml) and
[templates/docs-on-tag.yml](../templates/docs-on-tag.yml) into
`.github/workflows/` and adjust:

- **branches** (`docs-on-change.yml`): your default branch, plus any branch
  whose docs you want published as a preview prefix (each branch deploys to
  `<site-url>/<branch>/`).
- **paths**: the files that should trigger a re-deploy — your doc files,
  `_quarto.yml`, `index.md`, and the workflow itself.
- **default branch** (`docs-on-tag.yml`): both the `target-prefix` and the
  concurrency group say `main`; change to `master` etc. if needed. The
  concurrency group is shared with the branch-push workflow on purpose, so a
  tag deploy and a main-push deploy never race.

Both workflows guard on `if: ${{ vars.DOCS_SSH_DEST != '' }}` — they are
no-ops until the repo is configured ([repo-setup.md](repo-setup.md)), so
they're safe to merge ahead of time.

Pinning: the templates reference
`georgeharker/gh-quarto-publish/.github/workflows/publish.yml@main`, so every
consumer picks up workflow fixes automatically (dependency bumps, harness
changes). A third party who wants immutability can pin to a tag or commit SHA
instead. The docs-check harness is checked out at the exact commit the
workflow ref resolved to (`github.job_workflow_sha`), so workflow and harness
never skew either way.


## Social previews & extra assets

Link cards (Reddit, Slack, Discord, iMessage, X) are built from **Open Graph
tags**, which a bare `_quarto.yml` does not emit. Add under `website:`:

```yaml
site-url: https://docs.example.com/<project>   # canonical base
open-graph:
  image: https://docs.example.com/<project>/main/docs/images/og-card.png
  locale: en_US
twitter-card: true
```

Three rules learned the hard way:

- **The image URL must be absolute.** Crawlers do not resolve relative paths.
- **An absolute `open-graph.image` skips Quarto's auto-copy.** Quarto only
  copies images it can map to a local file, so an absolute URL ships *nothing*.
  Force-ship the file with `project.resources:`.
- **`project.resources` files land at their project-root-relative path.**
  `docs/images/og-card.png` publishes to `<site-url>/<branch>/docs/images/og-card.png`
  — the `/docs/` segment is easy to miss in the URL (and nothing 404s until a
  crawler asks). The deploy-time verification below catches exactly this.

And the operational rule: **share after the first green deploy.** Reddit caches
the preview at submission time, effectively permanently — a 404 card on the
first post never self-heals; delete and resubmit.

The publish workflow verifies what it ships: after rsync it curls the deployed
root and any absolute `og:image` found in the rendered index, failing the job
on a non-200 — so a broken card is a red check, not a surprise on Reddit.

## 2. `_quarto.yml`

Start from [templates/_quarto.yml](../templates/_quarto.yml). The rules that
bite:

- **READMEs must be listed explicitly** in `render:` — glob entries like
  `docs/*.md` deliberately skip `README.md` files (a Quarto behavior).
- **Every `.md` file a rendered page links to must itself be rendered**, or
  the link 404s on the published site. The check harness enforces this
  ("render-list reachability"), which sometimes pulls in files you didn't
  plan to publish (e.g. a `module/README.md` your main README links to).
- **Repo-only documents** (design records, maintainer notes, scratch) are
  excluded with `- "!docs/whatever.md"` — and then nothing rendered may link
  to them.
- Keep `from: markdown+gfm_auto_identifiers`: it makes Quarto's heading
  anchors match GitHub's slugs, so `#section-links` work in both places. Do
  not switch to `from: gfm` — it breaks Quarto's navigation divs.
- `embed-resources: true` makes each page self-contained, which keeps the
  rsync'd site free of shared asset directories. Note the consequence: every
  external image is **fetched and inlined at render time**, so an unreachable
  image host turns into a `[WARNING]` and fails the zero-warning gate.
- **Badges are stripped for you.** `img.shields.io` images (and their wrapping
  link) are removed during render by a harness filter, so keep badges in your
  README as ordinary markdown — GitHub renders them, the published site omits
  them, and shields.io is never contacted during the build. You do not need any
  markup or config for this.
- **Caveat:** the deploy profile sets `filters:`, which *replaces* a
  `filters:` list in your own `_quarto.yml` for the published render. Put
  filters you want shared in the harness (`filters/*.lua`) rather than per-repo;
  a repo-local filter still applies to local `quarto render`.

## 3. `index.md` landing page

The site needs a home page distinct from the README (the README renders as
"Overview"). Start from [templates/index.md](../templates/index.md): a
one-paragraph pitch, a link to the README, and — only if the repo has
several docs — an "I want to…" table routing to them.

Use ATX headings (`## Section`) in all published markdown. Setext headings
(underlined with `---`/`===`) are not collected as anchor targets by the
check harness, so `#links` to them fail the gate.

## 4. `.gitignore`

```gitignore
/_site/
/.quarto/
**/*.quarto_ipynb
_quarto-deploy.yml
```

`_quarto-deploy.yml` is generated by the workflow at render time (it injects
the deploy `site-url`); it should never be committed.

## 5. README backlink to the published site

Add a pointer near the top of the README so GitHub readers find the rendered
docs (and each published branch). Convention:

```markdown
> 📖 Rendered documentation:
> [docs.example.com/<project>](https://docs.example.com/<project>/)
> · [dev](https://docs.example.com/<project>/dev/)
```

The bare project URL works because the server redirects it to `main/`
([server-setup.md](server-setup.md), `.htaccess`). List a `dev` link only if
the repo actually publishes a dev prefix.

## 6. Checking locally

The harness needs no per-repo copy — run it from a checkout of this repo,
inside the consumer repo's root:

```bash
cd ~/src/<project>
zsh ~/src/gh-quarto-publish/scripts/check-docs.zsh
```

It validates every tracked markdown file plus the render list: relative
links and images resolve, `#anchors` hit real (ATX) headings, and every
`.md` linked from a rendered page is itself on the render list. A local
`quarto render` then reproduces the deploy's zero-warning gate (deploys
fail CI on any Quarto warning).

If a repo needs extra repo-specific checks, commit its own
`scripts/check-docs.zsh` — when that file exists, the workflow runs it
instead of the shared harness.
