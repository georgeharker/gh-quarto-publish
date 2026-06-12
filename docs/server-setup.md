# Server Setup

One-time setup of the docs host, plus a per-project section to repeat for
each published repo. Examples use generic names throughout — substitute your
own host (`docs-host.example.net`), SSH user (`docsuser`), public site
(`https://docs.example.com`), and docroot
(`~/public_html/docs.example.com`). Any shared host with SSH, rsync, and
Apache-style `.htaccess` support works.

## Layout

Each project gets its own directory under the docs docroot, with one
subdirectory per published prefix (branch):

```
~/public_html/docs.example.com/
├── .htaccess            # one file for the whole docs site, see below
├── <project-a>/
│   ├── main/            # rendered site for main (also refreshed on tags)
│   └── dev/             # rendered site for dev (if previews are enabled)
└── <project-b>/
    └── ...
```

The GitHub side never sees this layout: the workflow rsyncs to `:/main/`
and the server-side rrsync forced command confines that path to the
project's directory.

## One-time: install rrsync

`rrsync` (restricted rsync) is a wrapper shipped with rsync that pins an
incoming rsync connection to a single directory subtree. Many shared hosts
don't put it on `PATH`, but it's a single script:

```bash
# On the docs host. First check the installed rsync version — the rrsync
# script must come from the same release line:
rsync --version | head -1

# Locations vary; check whether the host already ships rrsync:
ls /usr/share/rsync/scripts/rrsync /usr/bin/rrsync 2>/dev/null

# If present, copy it into ~/bin:
mkdir -p ~/bin
cp /usr/share/rsync/scripts/rrsync ~/bin/rrsync
chmod +x ~/bin/rrsync

# If not, download it from the rsync source tree, pinned to the tag
# matching the host's rsync version (here 3.2.7):
mkdir -p ~/bin
curl -fsSL -o ~/bin/rrsync \
    https://raw.githubusercontent.com/RsyncProject/rsync/v3.2.7/support/rrsync
chmod +x ~/bin/rrsync

# Verify it runs (rsync >= 3.2.4 ships a python3 rrsync; older releases
# ship perl — pick whichever interpreter your host actually has):
head -1 ~/bin/rrsync
~/bin/rrsync 2>&1 | head -2   # usage message means the interpreter works
```

## One-time: docroot `.htaccess`

One `.htaccess` at the docs docroot covers every project — published sites
are static content, so lock the directory down and add the bare-URL
redirect. It lives outside the per-prefix directories, so the workflow's
`rsync --delete` never touches it.

```apache
# ~/public_html/docs.example.com/.htaccess — static content only, no PHP,
# long cache.

# Block PHP execution (works under mod_php and PHP-FPM).
<FilesMatch "\.(php|phtml|php[0-9]|phar)$">
  Require all denied
</FilesMatch>

# Caching: embed-resources pages are self-contained, so HTML is the only
# thing that needs to refresh quickly.
<IfModule mod_expires.c>
  ExpiresActive On
  ExpiresDefault "access plus 7 days"
  ExpiresByType text/html "access plus 1 hour"
</IfModule>

# Directory listing off.
Options -Indexes

# Bare project URLs land on the main docs; branch-prefixed URLs untouched.
# Generic: any /<segment> redirects to /<segment>/main/ if (and only if)
# that directory actually contains a main/ — no per-project list to
# maintain.
#
# Isolation from parent rewrites (e.g. a WordPress install above this
# directory): turning RewriteEngine on here REPLACES the parent's
# per-directory rules for this subtree — Apache does not merge them.
# IgnoreInherit (Apache 2.4.8+) additionally refuses rules a parent tries
# to force down with RewriteOptions InheritDown, which some WP security
# plugins and hosting panels add.
RewriteEngine On
RewriteOptions IgnoreInherit
RewriteCond %{REQUEST_FILENAME}/main -d
RewriteRule ^([^/]+)/?$ $1/main/ [R=302,L]
```

Note the deployed prefix directories themselves stay `.htaccess`-free by
construction — the workflow's `rsync --delete` removes anything (including
`.htaccess` files a plugin might plant) that isn't in the rendered site, so
this file is the only rewrite authority below the docroot. Rules defined in
the server/vhost config (rather than a parent `.htaccess`) run before any
per-directory processing and can't be disabled from here — if a redirect
behaves oddly, verify with the probes below and take it up with the host.

After deploying a first project, verify the isolation:

```bash
# Bare project URL → 302 to /<project>/main/ (our rule, not WP's):
curl -sI https://docs.example.com/<project> | grep -i '^location'

# Deep file serves directly (no WP cookies/headers in the response):
curl -sI https://docs.example.com/<project>/main/index.html | head -5

# A nonexistent path should return the host's plain 404 — if you get a
# themed WordPress 404 page, WP's front controller is still catching
# requests in this subtree:
curl -s https://docs.example.com/<project>/no-such-page | head -5
```

If your default branch is `master` for some projects, either symlink
`main -> master` in that project's directory or duplicate the
cond/rule pair with `master`.

Optionally restrict branch previews (e.g. `dev/`) with basic auth at the
docroot level:

```apache
# Require auth for dev/ prefixes only.
SetEnvIf Request_URI "^/[^/]+/dev/" DOCS_PREVIEW
AuthType Basic
AuthName "docs preview"
AuthUserFile /home/docsuser/.htpasswd
<RequireAny>
  <RequireAll>
    Require all granted
    Require not env DOCS_PREVIEW
  </RequireAll>
  Require valid-user
</RequireAny>
```

Create the password file with `htpasswd -c ~/.htpasswd <user>` (omit `-c`
when adding more users).

## Per project

### 1. Create the docroot

```bash
# On the docs host:
mkdir -p ~/public_html/docs.example.com/<project>
```

### 2. Generate a deploy keypair

One keypair per project, so a leaked key only ever reaches that project's
directory. Generate it on your workstation (the private key goes to GitHub,
never to the docs host):

```bash
ssh-keygen -t ed25519 -N '' \
    -f ~/.ssh/github-deploy-docs-<project> \
    -C github-deploy-docs-<project>
```

### 3. Add the forced-command key to the docs host

Append one line to `~/.ssh/authorized_keys` on the docs host — the public
key, prefixed with `restrict` and a `command=` that confines it to the
project directory in write-only mode:

```
restrict,command="/home/docsuser/bin/rrsync -wo /home/docsuser/public_html/docs.example.com/<project>" ssh-ed25519 AAAA... github-deploy-docs-<project>
```

- `restrict` disables PTY allocation, port/agent/X11 forwarding — everything
  except the forced command.
- `command="... rrsync -wo <dir>"` ignores whatever command the client asks
  for and runs rrsync instead; `-wo` makes the key write-only (the workflow
  can publish but never read), and all paths the client sends are resolved
  inside `<dir>`.
- Use absolute paths in `command=` — `~` is not expanded there.

The workflow's rsync destination is just `docsuser@docs-host.example.net:/main/`;
the `/main/` resolves under the confined directory.

### 4. Pin the host key

The workflow uses strict host-key checking against a pinned `known_hosts`
line rather than trusting first use. Capture it from your workstation:

```bash
ssh-keyscan -t ed25519 docs-host.example.net 2>/dev/null
```

The output (one line, `docs-host.example.net ssh-ed25519 AAAA...`) becomes
the `DOCS_HOST_KEY` secret — see [repo-setup.md](repo-setup.md).

### 5. Smoke-test the confinement

From your workstation, verify the deploy key can write only where intended:

```bash
# Should succeed (lands in <project>/main/ on the host):
echo ok > /tmp/probe.txt
rsync -e "ssh -i ~/.ssh/github-deploy-docs-<project>" /tmp/probe.txt \
    docsuser@docs-host.example.net:/main/probe.txt

# Should FAIL (path escapes the confined root):
rsync -e "ssh -i ~/.ssh/github-deploy-docs-<project>" /tmp/probe.txt \
    docsuser@docs-host.example.net:/../escape.txt

# Should FAIL (key is write-only):
rsync -e "ssh -i ~/.ssh/github-deploy-docs-<project>" \
    docsuser@docs-host.example.net:/main/probe.txt /tmp/
```

Remove the probe afterwards (e.g. via your normal shell access).
