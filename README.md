# wsl-kickstart

> Two bash scripts that turn a fresh WSL Ubuntu image into a fully-loaded
> development machine — interactive [gum](https://github.com/charmbracelet/gum)
> menus included.

![bash](https://img.shields.io/badge/bash-4%2B-4EAA25?logo=gnu-bash&logoColor=white)
![platform](https://img.shields.io/badge/platform-WSL2%20%C2%B7%20Ubuntu-0078D4)
![interface](https://img.shields.io/badge/interface-TUI%20via%20gum-FF6EC7)
![PRs](https://img.shields.io/badge/PRs-welcome-brightgreen)

Spin up a new WSL distro, clone this repo, run two scripts and pick what you
want from a pretty multi-select menu. When the dust settles you have your dev
box back — Docker, GitHub CLI, gcloud, Terraform, PowerShell, Python, Node.js
and the usual CLI suspects, all installed from their **official signed apt
repositories** (no random PPAs, no tarball roulette).

## Highlights

- **🍱 Interactive multi-select menu** — powered by
  [gum](https://github.com/charmbracelet/gum); toggle with `space`/`x`,
  confirm, done.
- **🕰️ Remembers your old machine** — feed it an exported `apt` history and
  every recipe you had before comes back pre-checked.
- **🧩 Ten curated recipes** — each installs from the vendor's own repo
  (Docker, GitHub, Google, HashiCorp, Microsoft, NodeSource…).
- **🧯 Fault tolerant** — recipes install one by one; a failure shows up in
  the summary but never aborts the run.
- **🔁 Idempotent** — both scripts are safe to re-run.
- **🎨 Themeable** — every colour is an environment variable (see
  [Theming](#theming)).

## The scripts

| file                      | purpose                                                           |
| ------------------------- | ----------------------------------------------------------------- |
| `01-install-gum.sh`       | bootstraps gum via the Charm apt repo and reloads `~/.bashrc`     |
| `02-install-software.sh`  | gum multi-select menu; installs the chosen recipes **one by one**  |

Requirements: WSL2 Ubuntu, bash 4+, `sudo` rights (plus `curl` & `gpg` for the
first script).

## Quickstart

```bash
git clone https://github.com/AlexDubel/wsl-kickstart.git
cd wsl-kickstart
./01-install-gum.sh
./02-install-software.sh
```

## Recipes

Ten curated recipes — the list mirrors the apt-install history of the dev
machine this repo replaced:

```text
docker            Docker Engine — docker-ce + buildx + compose plugin
gh                GitHub CLI — gh from the official apt repo
google-cloud-cli  Google Cloud CLI — gcloud from Google's apt repo
terraform         Terraform — HashiCorp apt repo
powershell        PowerShell — Microsoft apt repo; universal .deb fallback
python3           Python 3 — pip + venv + is-python3 + dev headers
git               Git
build-essential   Build tools — gcc + g++ + make
cli-utils         CLI utilities — jq unzip zip fzf ripgrep tree htop
nodejs            Node.js LTS — NodeSource repo (includes npm)
```

`./02-install-software.sh --list` prints the same list from the script.

### Usage

```bash
./02-install-software.sh                        # interactive menu
./02-install-software.sh docker python3         # install recipes directly
./02-install-software.sh --list                 # list recipes
./02-install-software.sh --show-history         # apt-history preselect analysis
./02-install-software.sh --history FILE         # preselect from an exported apt history
./02-install-software.sh --help
```

### Preselect from your old machine's apt history

The menu pre-checks any recipe whose marker package appears in the apt
history. On a fresh image the local history is empty, so export it from the
old machine first:

```bash
# on the OLD machine
{ cat /var/log/apt/history.log 2>/dev/null; zcat /var/log/apt/history.log.*.gz 2>/dev/null; } \
    > apt-history-export.log

# copy apt-history-export.log over, then on the NEW image:
./02-install-software.sh --history apt-history-export.log
./02-install-software.sh --show-history     # see what would be pre-checked
./02-install-software.sh                    # menu opens with those entries ticked
```

## Theming

Both scripts take their colours from environment variables (term256 colour
numbers like `196`, or hex like `#ff5f00` once gum is installed):

| variable        | used for              | default |
| --------------- | --------------------- | ------- |
| `THEME_PRIMARY` | headings / banners    | `212`   |
| `THEME_SUCCESS` | success messages      | `46`    |
| `THEME_ERROR`   | errors                | `196`   |
| `THEME_INFO`    | step / info messages  | `39`    |
| `THEME_MUTED`   | hints / footnotes     | `245`   |
| `THEME_CURSOR`  | menu cursor colour    | `212`   |
| `THEME_SELECTED`| selected item colour  | `46`    |

`THEME_CURSOR` / `THEME_SELECTED` only apply to `02-install-software.sh`'s
menu. Example — an orange theme:

```bash
THEME_PRIMARY=214 THEME_SUCCESS=76 THEME_ERROR=196 \
THEME_CURSOR=214 THEME_SELECTED=214 ./02-install-software.sh
```

The scripts also set gum's own env vars (`GUM_CHOOSE_*`, `GUM_CONFIRM_*`)
from these theme values, so menus, prompts and confirmations all match.

## Adding your own recipe

Open `02-install-software.sh` and:

1. add the key to `MENU_ORDER`
2. describe it in `RECIPES[key]="…"` — **avoid commas** (gum's `--selected`
   list is comma-separated)
3. set `MARKERS[key]="pkg …"` — apt package(s) that mark it as previously
   installed
4. write an `install_<key>()` function (dashes in the key become
   underscores, e.g. `google-cloud-cli` → `install_google_cloud_cli`)

Return non-zero from the function to flag the recipe as failed in the
summary; a failing recipe never aborts the rest of the run.

## Notes & caveats

- **Menu keybindings**: gum v2 (the version shipped by the Charm apt repo)
  has a bug — its multi-select toggle binding includes the space key, but a
  bubbletea v2 key-matching quirk means a real space press never fires it,
  and gum exposes no way to rebind keys. `02-install-software.sh` therefore
  runs the menu through a tiny python3 PTY shim that maps `space` → `x`, so
  **space and x both toggle** items. Without python3 it falls back to plain
  gum (x/tab still toggle).
- **PowerShell on brand-new Ubuntu releases**: Microsoft's apt repo
  (`packages.microsoft.com`) can lag behind a new Ubuntu release — on 26.04
  (resolute) it currently only carries `powershell-preview`, so
  `apt install powershell` fails with "Unable to locate package". The recipe
  detects this and falls back to the universal `.deb` from the official
  GitHub release, as Microsoft's install guide recommends. It installs the
  same `powershell` package name, so plain `apt upgrade` keeps it current
  once the repo catches up.
- **Docker on WSL**: for `systemctl` support enable systemd in
  `/etc/wsl.conf` (`[boot]` → `systemd=true`); otherwise the script falls
  back to `sudo service docker start`. The optional `docker` group prompt
  needs a re-login (`newgrp docker`) to take effect.
- Both scripts are idempotent: safe to re-run.
