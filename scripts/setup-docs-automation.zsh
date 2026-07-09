#!/usr/bin/env zsh
#
# setup-docs-automation — provision the GitHub Actions deploy key, secrets
# and variables used to publish a project's docs to a static-hosting server.
#
# It generates a dedicated ed25519 deploy key, optionally hands it to a
# secret manager, then sets on the target repo:
#   DOCS_DEPLOY_KEY  (secret)    private deploy key
#   DOCS_HOST_KEY    (secret)    known_hosts entry for the deploy host
#   DOCS_SSH_DEST    (variable)  user@host ssh/rsync destination
#   DOCS_SITE_URL    (variable)  public URL of the published docs
#
# Finally it appends a restricted (restrict + forced rrsync command) line for
# the deploy key to ~/.ssh/authorized_keys on the docs host, confining it to
# write-only rsync into that project's docs directory, and creates that dir.
# This last step ssh'es to the host using your own interactive credentials.
# See: docs/server-setup.md and docs/repo-setup.md
#
# Usage:
#   setup-docs-automation.zsh [-R <owner/repo>] [-f] [-S] <project> [url-path]
#
#   project    short name, e.g. svg-mcp (drives the key name + defaults)
#   url-path   path under the docs site (defaults to <project>)
#   -R         target repo (defaults to the repo in the current directory)
#   -f         regenerate the deploy key even if it already exists
#   -S         skip the host authorized_keys step (GitHub side only)
#
# Configuration — each value may be set by a flag or its DOCS_* environment
# variable (flag wins); e.g. a personal wrapper can export the env vars. See
# --help for the full flag/env list. Required: host, ssh-user, base-url.
# The deploy host (DOCS_HOST) is used for ssh-keyscan and the CI DOCS_SSH_DEST;
# the local authorize-over-ssh step uses DOCS_ALIAS (defaults to DOCS_HOST),
# so an ssh-config alias with custom user/port/key can be used locally without
# affecting what the GitHub runner connects to.
# The key-import command is optional (invoked as "<cmd> <key_name> <key_path>");
# if unset the private key is left on disk only.

set -euo pipefail

die() { print -u2 -- "setup-docs-automation: $*"; exit 1; }

# Turn silent `set -e` aborts into a diagnostic naming the failing line.
trap 'print -u2 -- "setup-docs-automation: aborted at line $LINENO"; exit 1' ERR

usage() {
  cat <<'EOF'
setup-docs-automation — provision the deploy key, secrets and variables
used to publish a project's docs to a static-hosting server.

Usage:
  setup-docs-automation.zsh [-R <owner/repo>] [-f] [-S] <project> [url-path]

  project    short name, e.g. svg-mcp (drives the key name + defaults)
  url-path   path under the docs site (defaults to <project>)
  -R         target repo (defaults to the repo in the current directory)
  -f         regenerate the deploy key even if it already exists
  -S         skip the host authorized_keys step (GitHub side only)

Sets DOCS_DEPLOY_KEY, DOCS_HOST_KEY (secrets) and DOCS_SSH_DEST,
DOCS_SITE_URL (variables) on the target repo, then authorizes the deploy
key on the docs host (restricted, write-only rrsync into the project dir).

Configuration — set via flag or environment variable (flag wins).
Required unless noted; flag / env-var / meaning:
  --host        DOCS_HOST            deploy host, e.g. host.example.net
                                     (used for ssh-keyscan + DOCS_SSH_DEST/CI)
  --alias       DOCS_ALIAS           optional: ssh target for the local
                                     authorize step (default: DOCS_HOST); set
                                     to an ssh-config alias if the host needs
                                     custom connection settings
  --ssh-user    DOCS_SSH_USER        ssh user on the host
  --base-url    DOCS_BASE_URL        docs site base URL, e.g. https://docs.example.com
  --key-import  DOCS_KEY_IMPORT_CMD  optional: command to store the private key,
                                     invoked as "<cmd> <key_name> <key_path>"
  --remote-home DOCS_REMOTE_HOME     optional (default: /home/$DOCS_SSH_USER)
  --docroot     DOCS_REMOTE_DOCROOT  optional: docroot the URL maps to
                                     (default: $DOCS_REMOTE_HOME/public_html/<host-of-base-url>)
  --rrsync      DOCS_RRSYNC          optional (default: $DOCS_REMOTE_HOME/bin/rrsync)
EOF
  exit "${1:-0}"
}

repo=""
force=0
skip_server=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -R|--repo) repo="${2:-}"; shift 2 ;;
    -f|--force) force=1; shift ;;
    -S|--skip-server) skip_server=1; shift ;;
    # Config flags — override the matching DOCS_* environment variable.
    --host)        DOCS_HOST="${2:-}"; shift 2 ;;
    --alias)       DOCS_ALIAS="${2:-}"; shift 2 ;;
    --ssh-user)    DOCS_SSH_USER="${2:-}"; shift 2 ;;
    --base-url)    DOCS_BASE_URL="${2:-}"; shift 2 ;;
    --key-import)  DOCS_KEY_IMPORT_CMD="${2:-}"; shift 2 ;;
    --remote-home) DOCS_REMOTE_HOME="${2:-}"; shift 2 ;;
    --docroot)     DOCS_REMOTE_DOCROOT="${2:-}"; shift 2 ;;
    --rrsync)      DOCS_RRSYNC="${2:-}"; shift 2 ;;
    -h|--help) usage 0 ;;
    --) shift; break ;;
    -*) die "unknown option: $1 (try -h)" ;;
    *) break ;;
  esac
done

(( $# >= 1 )) || usage 1

project="$1"
url_path="${2:-$project}"

# gh needs its own stored auth, not whatever GH_TOKEN/GITHUB_TOKEN is exported.
gh() { command env -u GH_TOKEN -u GITHUB_TOKEN gh "$@"; }
gh_args=()
[[ -n "$repo" ]] && gh_args=(-R "$repo")

# --- preflight ----------------------------------------------------------
command -v gh >/dev/null         || die "gh CLI not found on PATH"
command -v ssh-keygen >/dev/null || die "ssh-keygen not found on PATH"
gh auth status >/dev/null 2>&1   || die "gh is not authenticated (run: gh auth login)"

# Required config (no generic default — set via the environment / a wrapper).
[[ -n "${DOCS_HOST:-}" ]]     || die "DOCS_HOST is not set (deploy host)"
[[ -n "${DOCS_SSH_USER:-}" ]] || die "DOCS_SSH_USER is not set (ssh user on the host)"
[[ -n "${DOCS_BASE_URL:-}" ]] || die "DOCS_BASE_URL is not set (docs site base URL)"

# Optional config, derived from the required values.
: "${DOCS_KEY_IMPORT_CMD:=}"
: "${DOCS_ALIAS:=$DOCS_HOST}"   # ssh target for the local authorize step
: "${DOCS_REMOTE_HOME:=/home/${DOCS_SSH_USER}}"
_docs_domain="${DOCS_BASE_URL#*://}"; _docs_domain="${_docs_domain%%/*}"
: "${DOCS_REMOTE_DOCROOT:=${DOCS_REMOTE_HOME}/public_html/${_docs_domain}}"
: "${DOCS_RRSYNC:=${DOCS_REMOTE_HOME}/bin/rrsync}"

if [[ -n "$repo" ]]; then
  gh repo view "$repo" >/dev/null 2>&1 || die "cannot access repo: $repo"
else
  gh repo view >/dev/null 2>&1 || \
    die "no repo in $(pwd); run inside the target repo or pass -R <owner/repo>"
fi

key_name="github-deploy-docs-${project}"
key_path="$HOME/.ssh/${key_name}"
ssh_dest="${DOCS_SSH_USER}@${DOCS_HOST}"     # real host: ssh-keyscan + DOCS_SSH_DEST (CI)
ssh_local="${DOCS_SSH_USER}@${DOCS_ALIAS}"   # alias: local authorize-over-ssh step
site_url="${DOCS_BASE_URL%/}/${url_path}"
remote_dir="${DOCS_REMOTE_DOCROOT%/}/${url_path}"

print -- "Project:     $project"
print -- "Repo:        ${repo:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
print -- "Deploy key:  $key_path"
print -- "Destination: $ssh_dest"
[[ "$ssh_local" != "$ssh_dest" ]] && print -- "SSH (local): $ssh_local"
print -- "Site URL:    $site_url"
print -- "Key store:   ${DOCS_KEY_IMPORT_CMD:-(none — key left on disk only)}"
(( skip_server )) || print -- "Remote dir:  $ssh_dest:$remote_dir"
print

# --- deploy key ---------------------------------------------------------
if [[ -f "$key_path" ]]; then
  if (( force )); then
    print -- "Regenerating existing key (-f): $key_path"
    rm -f -- "$key_path" "${key_path}.pub"
    ssh-keygen -t ed25519 -N '' -f "$key_path" -C "$key_name"
  else
    print -- "Reusing existing key: $key_path (pass -f to regenerate)"
  fi
else
  ssh-keygen -t ed25519 -N '' -f "$key_path" -C "$key_name"
fi

# --- store private key (optional) ---------------------------------------
if [[ -n "$DOCS_KEY_IMPORT_CMD" ]]; then
  cmd=(${(z)DOCS_KEY_IMPORT_CMD})   # allow fixed args in the command string
  command -v "${cmd[1]}" >/dev/null || die "DOCS_KEY_IMPORT_CMD not found: ${cmd[1]}"
  "${cmd[@]}" "$key_name" "$key_path"
else
  print -- "No DOCS_KEY_IMPORT_CMD set; private key left at $key_path only."
fi

# --- GitHub secrets + variables ----------------------------------------
host_key="$(ssh-keyscan -t ed25519 "$DOCS_HOST" 2>/dev/null)" || true
[[ -n "$host_key" ]] || \
  die "ssh-keyscan returned nothing for '$DOCS_HOST' — is it a resolvable hostname (not an ssh-config alias)?"

gh secret   set DOCS_DEPLOY_KEY "${gh_args[@]}" < "$key_path"
gh secret   set DOCS_HOST_KEY   "${gh_args[@]}" --body "$host_key"
gh variable set DOCS_SSH_DEST   "${gh_args[@]}" --body "$ssh_dest"
gh variable set DOCS_SITE_URL   "${gh_args[@]}" --body "$site_url"

# --- host: authorize key + create docs dir ------------------------------
# Append a restricted authorized_keys line confining the key to a write-only
# rrsync into this project's docs dir, and create that dir. Runs over ssh
# using your own interactive credentials (not the deploy key).
if (( skip_server )); then
  print -- "Skipping host authorized_keys step (-S)."
else
  pub="$(<"${key_path}.pub")"
  pub_blob="${${(z)pub}[2]}"   # the base64 body, used to dedup the line
  keyline="restrict,command=\"${DOCS_RRSYNC} -wo ${remote_dir}\" ${pub}"

  # The values are ${(q)}-quoted into a prelude so they survive the remote
  # POSIX shell; the body is a quoted heredoc that runs verbatim on the host
  # (its $HOME/$REMOTE_DIR/etc. are expanded there, not locally).
  remote_body="$(cat <<'REMOTE'
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
# The docroot must be world-traversable so the web server can reach the
# published files — do NOT let the .ssh umask leak onto it. chmod (not just
# a umask) so a re-run also repairs a dir an older version created as 700.
mkdir -p "$REMOTE_DIR"
chmod 755 "$REMOTE_DIR"
echo "docs dir ready: $REMOTE_DIR"
if grep -qF "$PUB_BLOB" "$HOME/.ssh/authorized_keys"; then
  echo "authorized_keys: deploy key already present"
else
  printf "%s\n" "$KEYLINE" >> "$HOME/.ssh/authorized_keys"
  echo "authorized_keys: deploy key added"
fi
[ -x "$RRSYNC" ] || echo "WARNING: rrsync not found/executable at $RRSYNC (forced command will fail until installed)"
REMOTE
)"
  remote_script="set -eu
REMOTE_DIR=${(q)remote_dir}
RRSYNC=${(q)DOCS_RRSYNC}
PUB_BLOB=${(q)pub_blob}
KEYLINE=${(q)keyline}
${remote_body}"

  print -- "Authorizing key on $ssh_local ..."
  ssh "$ssh_local" sh -s <<< "$remote_script"
fi

print
print -- "Done. Docs deploy automation configured for '$project'."
