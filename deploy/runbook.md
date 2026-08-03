# somisana-ops — server runbook

Operational setup for the machine that runs the forecast system (`mims3`, hostname
`croco`). Written to be readable standalone so it can be copied into, or linked from, the
repo wiki.

> **Design context:** see `plans/operational_workflow_plan.md`. This runbook covers *how to
> set the server up*; the plan covers *why it is built this way*.

---

## 1. GitHub CLI (`gh`) setup

### Why `gh` is needed

Two things on the server must authenticate to GitHub:

- **git** — `clone`, `pull` (the per-cycle `sync_repos.sh`, D22) and `push` during development
- **the `gh` CLI** — `gh workflow run`, which is how the dispatcher triggers every workflow (D2)

GitHub has not accepted passwords over HTTPS since 2021, so both need a **token**.
`gh auth login` obtains one and stores it in `~/.config/gh/hosts.yml`; `gh auth setup-git`
then tells `git` to reuse it.

### ⚠ Two traps before you start

**All repos are cloned over HTTPS, not SSH.** There is no SSH key on this server
(`~/.ssh` contains only `known_hosts`). Using an SSH URL fails with
`Permission denied (publickey)`, which reads like a permissions problem but simply means
"wrong protocol". Check an existing clone if in doubt:

```bash
git -C /home/somisana/code/somisana-croco remote -v
#   origin  https://github.com/SAEON/somisana-croco.git
```

**Do the authentication as `somisana`, not as your personal account.** The credential is
stored per-user, and the systemd timer plus the Actions runners run as `somisana`.
Authenticating as yourself leaves the dispatcher unauthenticated, and the resulting failure
is silent (see §1.6).

### 1.1 Install `gh` — as an admin user

`somisana`'s `sudo` is restricted to a specific allowlist and **cannot run `dnf`**:

```
Sorry, user somisana is not allowed to execute '/bin/dnf install ...' as root on croco
```

So install from an account with general sudo (e.g. `giles`). On AlmaLinux 10 / RHEL 10:

```bash
sudo dnf install -y 'dnf-command(config-manager)'
sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
sudo dnf install -y gh
```

Verify — it must land in a system path so that **systemd** can find it (see §1.7):

```bash
which gh          # /usr/bin/gh
gh --version      # gh version 2.97.0 (or later)
```

*(If no admin account is available, `gh` can be installed without root by unpacking the
release tarball from `github.com/cli/cli/releases` into `/home/somisana/bin` — but then
§1.7's PATH caveat applies to `gh` as well.)*

### 1.2 Create the Personal Access Token

On github.com → **Settings → Developer settings → Personal access tokens → Tokens (classic)**
→ *Generate new token (classic)*:

| field | value |
|---|---|
| **Note** | `mims3-somisana-ops` |
| **Expiration** | **No expiration** — see §1.6 |
| **Scopes** | ✅ `repo`  ✅ `workflow`  ✅ `read:org` |

Leave everything else unticked (`admin:*`, `delete_repo`, `write:packages`, …).

**Why each scope:**

- **`repo`** — `git push`, private-repo `clone`/`pull`, and the API calls behind `gh workflow run`.
- **`workflow`** — needed *twice*: to dispatch workflows, **and to push any change to
  `.github/workflows/*.yml`**. Without it GitHub rejects those pushes with an error that
  looks like a repository permissions problem rather than a token scope problem.
- **`read:org`** — `gh` validates org membership and SAML/SSO status at login. Without it,
  `gh auth login` fails outright with `error validating token: missing required scope 'read:org'`.

**Why classic rather than fine-grained.** Fine-grained tokens *must* have an expiry — there is
no "no expiration" option — which turns §1.6's silent-failure mode from a possibility into a
scheduled certainty. Classic is the sounder choice for an unattended system with no external
alerting.

**The cost, chosen deliberately:** classic `repo` is not per-repository. It grants read/write
to every repository the account can reach, and the token sits in plaintext on a shared
machine. Mitigate with file permissions (§1.5) and treat it as a credential of record.

Scopes on an existing classic token are **editable without regenerating it** — the token
string is unchanged. So a missing scope is fixed by ticking the box and pressing *Update
token*, not by starting over.

### 1.3 Authenticate as `somisana`

```bash
sudo -i -u somisana
gh auth login --with-token
# paste the token, press Enter, then Ctrl-D
```

**`--with-token` prints no prompt.** A blank cursor is correct behaviour, not a hang. It is
reading stdin and returns as soon as it receives EOF (Ctrl-D).

Pasting into stdin avoids writing the token to a file, and avoids
`echo <token> | gh auth login`, which would leave it in shell history.

If the interactive flow is preferred — it prompts properly and folds in §1.4:

```bash
gh auth login
#   → GitHub.com
#   → HTTPS
#   → Authenticate Git with your GitHub credentials?  Yes
#   → Paste an authentication token
```

### 1.4 Let `git` use the same token

Authenticating `gh` does **not** authenticate `git` — they are separate programs. Without
this step `gh` works while `git push` still prompts for a password that no longer exists.

```bash
gh auth setup-git      # silent on success
```

### 1.5 Verify

```bash
gh auth status
```

Expected:

```
github.com
  ✓ Logged in to github.com account GilesFearon (/home/somisana/.config/gh/hosts.yml)
  - Active account: true
  - Git operations protocol: https
  - Token: ghp_************************************
  - Token scopes: 'read:org', 'repo', 'workflow'
```

Check all four: the **account**, the **path** (must be under `/home/somisana`), the
**protocol** (`https`), and all three **scopes**.

Then confirm the token file is not world-readable — it holds the token in plaintext:

```bash
ls -l ~/.config/gh/hosts.yml      # want -rw------- (600)
```

### 1.6 ⚠ Token expiry is a silent, total failure

If the token expires or is revoked:

1. the dispatcher cannot call `gh workflow run`, so **nothing is dispatched**;
2. nothing is dispatched, so **no workflow runs**;
3. no workflow runs, so **nothing fails** — and GitHub only emails about failures;
4. **including the 12:00 completeness check (D16), which is itself dispatched via `gh`.**

The alerting depends on the very credential that broke, so the system goes completely quiet
and reports nothing wrong. This is why the token is created with **no expiration**.

If the security posture later requires an expiring token, an **external dead-man's switch
must be added first** (a periodic ping to a service that alerts on *absence*) — otherwise a
broad-blast-radius risk is simply traded for a guaranteed silent outage.

**On rotation:** revoke and reissue with the same three scopes, re-run §1.3–1.5. Because the
token is named `mims3-somisana-ops` it can be identified and revoked in isolation, without
disturbing `gh` on any other machine.

### 1.7 ⚠ PATH under systemd

systemd services run with a **minimal PATH** and do not read `~/.bashrc`. Two consequences:

- **`gh`** installed at `/usr/bin/gh` (§1.1) is fine. Installed to `~/bin` it is **not** —
  use an absolute path in the scripts, or set `Environment=PATH=…` in the unit file.
- **conda is never on the PATH.** Every script that uses it must source the hook explicitly,
  as the existing workflows already do:

  ```bash
  source /home/somisana/miniforge3/etc/profile.d/conda.sh
  ```

### 1.8 Clone the repository

```bash
cd /home/somisana/code
git clone https://github.com/SAEON/somisana-ops.git
```

Use **HTTPS for every repo** the dispatcher touches (`somisana-ops`, `somisana-croco`,
`somisana-download`, later `somisana-ww3` and `somisana-opendrift`). Mixing protocols means
two authentication mechanisms to keep working on a machine that runs unattended.

### 1.9 ⚠ Keep the operational clone clean

During bring-up, `/home/somisana/code/somisana-ops` is both the development and the
operational clone. That is acceptable while building, but **`sync_repos.sh` pulls these
clones every cycle (D22) and assumes clean working trees.** A half-finished edit sitting in
that directory becomes a failed pull — or worse, silently runs uncommitted code in a live
forecast.

At cutover, make the operational clone **pull-only** and move development to a personal
clone under `/home/giles/`.

---

## 2. Still to document

- systemd unit installation (`deploy/systemd/`) — Phase 5
- conda environments and their provenance (`somisana_croco`, the download env)
- the passwordless `sudo` allowlist for `somisana` (`sudo -l`) that the archive steps rely on
- `.env` contents and rotation for `COPERNICUS_USERNAME` / `PASSWORD` on `saeonapps` (D19)
- test-vs-live root overrides for bring-up (D23)
