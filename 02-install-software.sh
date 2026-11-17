#!/usr/bin/env bash
# ============================================================================
# 02-install-software.sh — interactive software picker for a fresh WSL image.
#
# Reads the local apt history (or an exported one from your old machine),
# pre-checks matching entries in a gum multi-select menu, then installs the
# chosen recipes one by one.
#
# Usage:
#   ./02-install-software.sh                          interactive menu
#   ./02-install-software.sh docker python3           install recipes directly
#   ./02-install-software.sh --list                   list recipes
#   ./02-install-software.sh --show-history           show preselect analysis
#   ./02-install-software.sh --history FILE           use exported apt history
#   ./02-install-software.sh --help
#
# Requires gum → run ./01-install-gum.sh first. bash 4+, sudo rights.
#
# Theme overrides (env vars): THEME_PRIMARY THEME_SUCCESS THEME_ERROR
# THEME_INFO THEME_MUTED THEME_CURSOR THEME_SELECTED
# ============================================================================

set -uo pipefail    # no -e on purpose: one failing recipe must not kill the run

HISTORY_FILE=""

# ---------------------------------------------------------------------------
# Theme — colours for output and menus (override via environment variables)
# ---------------------------------------------------------------------------
THEME_PRIMARY="${THEME_PRIMARY:-212}"    # headings / banners
THEME_SUCCESS="${THEME_SUCCESS:-46}"     # success messages
THEME_ERROR="${THEME_ERROR:-196}"        # errors
THEME_INFO="${THEME_INFO:-39}"           # step / info messages
THEME_MUTED="${THEME_MUTED:-245}"        # hints / footnotes
THEME_CURSOR="${THEME_CURSOR:-212}"      # menu cursor colour
THEME_SELECTED="${THEME_SELECTED:-46}"   # selected menu item colour

# ---------------------------------------------------------------------------
# Output helpers — gum when available, plain ANSI 256-colour otherwise
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

style() { # style <bold 0|1> <colour> <text...>
    local bold="$1" colour="$2"; shift 2
    if have gum; then
        gum style "--bold=$bold" --foreground "$colour" "$*"
    else
        printf '\033[%s;38;5;%sm%s\033[0m\n' "$bold" "$colour" "$*"
    fi
}

hdr()    { style 1 "$THEME_PRIMARY" "▶ $*"; }
ok()     { style 0 "$THEME_SUCCESS" "✔ $*"; }
err()    { style 0 "$THEME_ERROR"   "✖ $*" >&2; }
info()   { style 0 "$THEME_INFO"    "· $*"; }
muted()  { style 0 "$THEME_MUTED"   "  $*"; }
step()   { style 0 "$THEME_INFO"    "    → $*"; }
die()    { err "$*"; exit 1; }

banner() {
    if have gum; then
        gum style --bold --border double --border-foreground "$THEME_PRIMARY" \
            --foreground "$THEME_PRIMARY" --padding "0 2" --margin "0 1" " $1 "
    else
        printf '\033[1;38;5;%sm== %s ==\033[0m\n' "$THEME_PRIMARY" "$1"
    fi
}

apply_gum_theme() { # gum env styling — unknown vars are simply ignored by gum
    export GUM_CHOOSE_CURSOR="❯ "
    export GUM_CHOOSE_CURSOR_FOREGROUND="$THEME_CURSOR"
    export GUM_CHOOSE_SELECTED_PREFIX="[x]"
    export GUM_CHOOSE_UNSELECTED_PREFIX="[ ]"
    export GUM_CHOOSE_SELECTED_FOREGROUND="$THEME_SELECTED"
    export GUM_CHOOSE_HEADER_FOREGROUND="$THEME_PRIMARY"
    export GUM_CONFIRM_SELECTED_BACKGROUND="$THEME_PRIMARY"
    export GUM_CONFIRM_SELECTED_FOREGROUND="0"
}

# ---------------------------------------------------------------------------
# gum choose wrapper — gum v2 (the version in the Charm apt repo) only reacts
# to "x"/"tab" for toggling a multi-select item: its toggle binding includes
# the space key, but a bubbletea v2 key-matching bug means a real space press
# never fires it, and gum offers no way to rebind keys. To keep "space toggle"
# working as advertised, we run gum choose under a small python3 PTY shim
# that translates space presses into "x". TUI output is relayed to stderr and
# the child inherits our stdout, so $() capture keeps working. Falls back to
# a direct gum call when python3 or a tty stdin is unavailable.
# ---------------------------------------------------------------------------
gum_space_shim_py=""
read -r -d '' gum_space_shim_py <<'PYSHIM' || true
import fcntl, os, pty, re, select, signal, sys, termios, tty

cmd = sys.argv[1:]
if not cmd or not os.isatty(0):
    if cmd:
        os.execvp(cmd[0], cmd)
    sys.exit(2)

master, slave = pty.openpty()

def copy_winsize(src_fd, dst_fd):
    try:
        fcntl.ioctl(dst_fd, termios.TIOCSWINSZ,
                    fcntl.ioctl(src_fd, termios.TIOCGWINSZ, b"\x00" * 8))
    except OSError:
        pass

copy_winsize(0, master)

pid = os.fork()
if pid == 0:  # gum: new session, pty slave as controlling tty + stdin/stderr
    os.close(master)
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    os.dup2(slave, 0)
    os.dup2(slave, 2)
    if slave > 2:
        os.close(slave)
    os.execvp(cmd[0], cmd)
    os._exit(127)

os.close(slave)

old_attrs = termios.tcgetattr(0)
tty.setcbreak(0)
# cbreak alone keeps ICRNL, which would turn Enter (\r) into \n (ctrl+j =
# "move down" for bubbletea); also drop IXON flow control.
attrs = termios.tcgetattr(0)
attrs[0] &= ~(termios.ICRNL | termios.INLCR | termios.IGNCR | termios.IXON)
termios.tcsetattr(0, termios.TCSANOW, attrs)

def on_winch(_signum, _frame):
    copy_winsize(0, master)

signal.signal(signal.SIGWINCH, on_winch)

# Match plain space as well as Kitty keyboard protocol (\x1b[32u / \x1b[32;1u)
# and xterm modifyOtherKeys (\x1b[27;1;32~) space sequences sent by modern
# terminals like Windows Terminal when bubbletea enables enhanced key reporting.
space_re = re.compile(rb"( |\x1b\[32(?:;[0-9:]+)?u|\x1b\[27;[0-9]+;32~)")
move_re = re.compile(rb"(\x1b\[[AB]|\x1bO[AB]|[jk])")
toggle_re = re.compile(rb"[x\ta]")
# Strip bubbletea's requests to enable Kitty keyboard protocol / modifyOtherKeys
# so the outer terminal stays in standard key mode.
kbd_mode_re = re.compile(rb"\x1b\[(?:>4(?:;[0-9]+)?m|>[0-9]*u|\?u|<[0-9]*u)")

auto_toggle_on_enter = os.environ.get("GUM_AUTO_TOGGLE_CURSOR") == "1"
toggled = False
moved = False

stderr_buf = sys.stderr.buffer
watch = [0, master]
try:
    while watch:
        r, _, _ = select.select(watch, [], [])
        if 0 in r:
            try:
                data = os.read(0, 1024)
            except OSError:
                data = b""
            if not data:
                watch.remove(0)
            else:
                # the actual fix: make SPACE toggle like "x" does
                if space_re.search(data):
                    data = space_re.sub(b"x", data)
                    toggled = True
                elif toggle_re.search(data):
                    toggled = True
                if move_re.search(data):
                    moved = True
                # If pre-checked [x] items exist (already-installed packages) and
                # the user moved the cursor to a package and pressed Enter without
                # pressing space/x first, toggle the cursor item before submitting.
                if auto_toggle_on_enter and not toggled and moved and b"\r" in data:
                    data = data.replace(b"\r", b"x\r", 1)
                    toggled = True
                os.write(master, data)
        if master in r:
            try:
                data = os.read(master, 65536)
            except OSError:
                break
            if not data:
                break
            stderr_buf.write(kbd_mode_re.sub(b"", data))
            stderr_buf.flush()
finally:
    termios.tcsetattr(0, termios.TCSADRAIN, old_attrs)
    signal.signal(signal.SIGWINCH, signal.SIG_DFL)
    try:
        os.close(master)
    except OSError:
        pass

_, status = os.waitpid(pid, 0)
if os.WIFEXITED(status):
    sys.exit(os.WEXITSTATUS(status))
if os.WIFSIGNALED(status):
    os.kill(os.getpid(), os.WTERMSIG(status))
sys.exit(1)
PYSHIM

run_gum_choose() { # run_gum_choose <gum choose args...> → selection on stdout
    if have python3 && [[ -t 0 ]]; then
        python3 -c "$gum_space_shim_py" gum choose "$@"
    else
        gum choose "$@"
    fi
}

# ---------------------------------------------------------------------------
# Recipes — to add your own: extend MENU_ORDER + RECIPES + MARKERS and write
# an install_<key>() function (dashes in the key become underscores).
# NOTE: keep descriptions comma-free — gum's --selected list is comma-separated.
# ---------------------------------------------------------------------------
MENU_ORDER=(
    docker
    k3s
    gh
    google-cloud-cli
    terraform
    powershell
    python3
    uv
    git
    build-essential
    cli-utils
    nodejs
)

declare -A RECIPES=(
    [docker]="Docker Engine — docker-ce + buildx + compose plugin"
    [k3s]="k3s — lightweight Kubernetes + optional helm/k9s tooling"
    [gh]="GitHub CLI — gh from the official apt repo"
    [google-cloud-cli]="Google Cloud CLI — gcloud from Google's apt repo"
    [terraform]="Terraform — HashiCorp apt repo"
    [powershell]="PowerShell — Microsoft apt repo; universal .deb fallback"
    [python3]="Python 3 — pip + venv + is-python3 + dev headers"
    [uv]="uv/uvx install — fast Python package and tool manager"
    [git]="Git"
    [build-essential]="Build tools — gcc + g++ + make"
    [cli-utils]="CLI utilities — jq unzip zip fzf ripgrep tree htop"
    [nodejs]="Node.js LTS — NodeSource repo (includes npm)"
)

# Package(s) whose appearance in the apt history mark a recipe as
# previously installed (used to pre-check menu entries).
declare -A MARKERS=(
    [docker]="docker-ce"
    [k3s]="k3s"
    [gh]="gh"
    [google-cloud-cli]="google-cloud-cli"
    [terraform]="terraform"
    [powershell]="powershell"
    [python3]="python-is-python3 python3-pip"
    [uv]=""
    [git]="git"
    [build-essential]="build-essential"
    [cli-utils]="jq"
    [nodejs]="nodejs"
)

APT_UPDATED=0

apt_update() { # apt_update [force]
    if [[ "${1:-}" == "force" ]] || (( ! APT_UPDATED )); then
        step "refreshing apt package index"
        sudo DEBIAN_FRONTEND=noninteractive apt-get update || return 1
        APT_UPDATED=1
    fi
}

apt_install() { # apt_install <label> <pkg...>
    local label="$1"; shift
    apt_update || return 1
    step "$label — apt install: $*"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

# ---------------------------------------------------------------------------
# Installers (one per recipe)
# ---------------------------------------------------------------------------
install_docker() {
    banner "Docker Engine"
    apt_install "prerequisites: ca-certificates + curl" ca-certificates curl || return 1
    step "Docker's official GPG key → /etc/apt/keyrings/docker.asc"
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
        || { err "failed to download Docker GPG key"; return 1; }
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    step "repository → /etc/apt/sources.list.d/docker.list"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    apt_update force || return 1
    apt_install "Docker Engine" docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
    step "starting the docker service (systemd or SysV — WSL supports both)"
    sudo systemctl enable --now docker 2>/dev/null \
        || sudo service docker start 2>/dev/null \
        || muted "could not auto-start docker — run: sudo service docker start"
    if id -nG "$USER" 2>/dev/null | grep -qw docker; then
        ok "'$USER' is already in the docker group."
    elif [[ -t 0 ]] && gum confirm "Add '$USER' to the 'docker' group (run docker without sudo)?"; then
        sudo usermod -aG docker "$USER"
        ok "'$USER' added to the docker group — re-login or 'newgrp docker' to apply."
    else
        muted "skipped docker group membership."
    fi
    have docker || { err "docker binary not found after install"; return 1; }
    ok "$(docker --version 2>/dev/null || sudo docker --version)"
}

install_k3s() {
    banner "k3s — lightweight Kubernetes"
    have curl || apt_install "curl prerequisite" curl || return 1
    local ver arch tag deb sel item waited=0
    local -a extras=()

    if have k3s; then
        ver="$(k3s --version 2>/dev/null | awk '{print $3}')"
        ok "k3s ${ver:-already present} — moving on to cluster setup."
    else
        step "running the official installer (get.k3s.io)"
        curl -sfL https://get.k3s.io | sudo sh - \
            || { err "k3s installer failed"; return 1; }
        have k3s || { err "k3s binary not found after install"; return 1; }
        ver="$(k3s --version 2>/dev/null | awk '{print $3}')"
        ok "k3s ${ver} installed (kubectl/crictl/ctr symlinks included)"
    fi

    if ! sudo k3s kubectl get nodes >/dev/null 2>&1; then
        step "starting k3s (systemd unit — or background start on non-systemd WSL)"
        sudo systemctl enable --now k3s 2>/dev/null \
            || sudo sh -c 'nohup k3s server </dev/null >>/var/log/k3s-server.log 2>&1 &' \
            || muted "could not auto-start k3s — run: sudo k3s server"
    fi

    step "waiting for the k3s API to answer (up to 120 s)"
    while ! sudo k3s kubectl get --raw /readyz >/dev/null 2>&1; do
        sleep 5
        waited=$((waited + 5))
        (( waited >= 120 )) && break
    done
    if sudo k3s kubectl get --raw /readyz >/dev/null 2>&1; then
        ok "cluster ready:"
        sudo k3s kubectl get nodes 2>/dev/null | tail -n +2 \
            | while IFS= read -r line; do info "$line"; done
    else
        err "k3s API not ready after ${waited} s"
        info "first start pulls container images — retry: sudo k3s kubectl get nodes"
        info "non-systemd WSL keeps the server log at /var/log/k3s-server.log"
        return 1
    fi

    step "kubeconfig for '$USER' → $HOME/.kube/config"
    mkdir -p "$HOME/.kube"
    install -m 600 /dev/null "$HOME/.kube/config" \
        || { err "could not secure $HOME/.kube/config"; return 1; }
    if sudo k3s kubectl config view --raw > "$HOME/.kube/config" 2>/dev/null; then
        ok "kubeconfig written (server https://127.0.0.1:6443 · chmod 600)"
    else
        err "could not write $HOME/.kube/config"
        return 1
    fi

    if have kubectl; then
        ok "kubectl already on PATH ($(command -v kubectl))"
    else
        sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl
        ok "kubectl symlinked → /usr/local/bin/kubectl (k3s multi-call binary)"
    fi

    step "optional Kubernetes tooling"
    if [[ -t 0 ]]; then
        local extra_header
        extra_header="$(gum style --bold 'Optional Kubernetes tooling')
space or x toggle · enter confirm · esc skip"
        sel="$(run_gum_choose --no-limit --header "$extra_header" \
            'helm — the Kubernetes package manager' \
            'k9s — terminal UI for clusters')" || sel=""
        [[ -n "$sel" ]] && mapfile -t extras < <(printf '%s\n' "$sel" | awk '{print $1}')
    else
        info "non-interactive shell — skipping the helm/k9s menu."
    fi

    for item in "${extras[@]}"; do
        case "$item" in
            helm)
                step "helm — official installer script (get-helm-4)"
                if curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | bash; then
                    have helm \
                        && ok "helm $(helm version --short 2>/dev/null)" \
                        || { err "helm binary not found after install"; return 1; }
                else
                    err "helm installer failed"; return 1
                fi
                ;;
            k9s)
                arch="$(dpkg --print-architecture)"    # amd64 / arm64
                deb="/tmp/k9s_linux_${arch}.deb"
                step "k9s — querying the latest GitHub release"
                tag="$(curl -fsSL https://api.github.com/repos/derailed/k9s/releases/latest \
                    | grep -oE '"tag_name":[[:space:]]*"v[0-9.]+"' | head -1 | grep -oE 'v[0-9.]+')" || true
                [[ -n "$tag" ]] || { err "could not determine the latest k9s release"; return 1; }
                step "downloading k9s ${tag} (linux/${arch})"
                curl -fsSL "https://github.com/derailed/k9s/releases/download/${tag}/k9s_linux_${arch}.deb" \
                    -o "$deb" || { err "download failed"; return 1; }
                step "installing $deb"
                if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb"; then
                    rm -f "$deb"
                    err "failed to install $deb"
                    return 1
                fi
                rm -f "$deb"
                have k9s || { err "k9s binary not found after install"; return 1; }
                ok "k9s ${tag#v} — launch with: k9s"
                ;;
        esac
    done
    (( ${#extras[@]} )) || muted "no extra tooling selected."
    muted "uninstall k3s later with: /usr/local/bin/k3s-uninstall.sh"
}

install_gh() {
    banner "GitHub CLI"
    have curl || apt_install "curl prerequisite" curl || return 1
    step "GPG key → /etc/apt/keyrings/githubcli-archive-keyring.gpg"
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null \
        || { err "failed to download GitHub CLI GPG key"; return 1; }
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    step "repository → /etc/apt/sources.list.d/github-cli.list"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    apt_update force || return 1
    apt_install "GitHub CLI" gh || return 1
    have gh || { err "gh binary not found after install"; return 1; }
    ok "$(gh --version | head -1)"
}

install_google_cloud_cli() {
    banner "Google Cloud CLI"
    local pkg prereqs_installed=1
    for pkg in ca-certificates curl gnupg apt-transport-https; do
        dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null \
            | grep -qx installed || prereqs_installed=0
    done
    if (( ! prereqs_installed )); then
        apt_install "prerequisites: ca-certificates + curl + gnupg + apt-transport-https" \
            ca-certificates curl gnupg apt-transport-https || return 1
    fi
    step "Google Cloud GPG key → /usr/share/keyrings/cloud.google.gpg"
    sudo install -m 0755 -d /usr/share/keyrings
    sudo rm -f /usr/share/keyrings/cloud.google.gpg   # idempotency
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
        || { err "failed to import Google Cloud GPG key"; return 1; }
    sudo chmod a+r /usr/share/keyrings/cloud.google.gpg
    step "repository → /etc/apt/sources.list.d/google-cloud-sdk.list"
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
    apt_update force || return 1
    apt_install "Google Cloud CLI" google-cloud-cli || return 1
    have gcloud || { err "gcloud binary not found after install"; return 1; }
    ok "gcloud installed — start with: gcloud init"
}

install_terraform() {
    banner "Terraform"
    have wget        || apt_install "wget prerequisite" wget               || return 1
    have gpg         || apt_install "gnupg prerequisite" gnupg             || return 1
    have lsb_release || apt_install "lsb_release prerequisite" lsb-release || return 1
    step "HashiCorp GPG key → /usr/share/keyrings/hashicorp-archive-keyring.gpg"
    sudo install -m 0755 -d /usr/share/keyrings
    sudo rm -f /usr/share/keyrings/hashicorp-archive-keyring.gpg   # idempotency
    wget -q -O - https://apt.releases.hashicorp.com/gpg \
        | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg \
        || { err "failed to import HashiCorp GPG key"; return 1; }
    sudo chmod a+r /usr/share/keyrings/hashicorp-archive-keyring.gpg
    step "repository → /etc/apt/sources.list.d/hashicorp.list"
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
        | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
    apt_update force || return 1
    apt_install "Terraform" terraform || return 1
    have terraform || { err "terraform binary not found after install"; return 1; }
    ok "terraform $(terraform version 2>/dev/null | head -1 | awk '{print $2}')"
}

install_powershell() {
    banner "PowerShell"
    have wget || apt_install "wget prerequisite" wget || return 1
    local os_id arch tag ver deb="/tmp/packages-microsoft-prod.deb"
    os_id="$(. /etc/os-release && echo "$VERSION_ID")"
    arch="$(dpkg --print-architecture)"    # amd64 / arm64

    # Route 1 — Microsoft's preferred method: the packages.microsoft.com apt repo.
    # https://learn.microsoft.com/powershell/scripting/install/install-ubuntu
    step "downloading Microsoft repo package for Ubuntu $os_id"
    if wget -q "https://packages.microsoft.com/config/ubuntu/$os_id/packages-microsoft-prod.deb" -O "$deb"; then
        step "installing repo package: $deb"
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb" || true
        rm -f "$deb"
        step "installing powershell from the Microsoft apt repo"
        if apt_update force && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y powershell && have pwsh; then
            ok "pwsh $(pwsh --version 2>/dev/null) — Microsoft apt repo"
            return 0
        fi
        # Repo configs can exist before the stable package is published — e.g.
        # Ubuntu 26.04 (resolute) only carries powershell-preview in PMC so far.
        info "Microsoft's $os_id repo has no stable 'powershell' package yet"
    else
        rm -f "$deb"
        info "no Microsoft repo config for Ubuntu $os_id"
    fi

    # Route 2 — Microsoft's documented fallback: manually download and install
    # the universal .deb from the GitHub stable release page. The .deb declares
    # its libicu dependency, so apt resolves it from the Ubuntu archive.
    step "querying the latest stable PowerShell release"
    tag="$(wget -qO- https://api.github.com/repos/PowerShell/PowerShell/releases/latest \
        | grep -oE '"tag_name":[[:space:]]*"v[0-9.]+"' | head -1 | grep -oE 'v[0-9.]+')" || true
    [[ -n "$tag" ]] || { err "could not determine the latest PowerShell release"; return 1; }
    ver="${tag#v}"
    deb="/tmp/powershell_${ver}-1.deb_${arch}.deb"
    step "downloading universal package: powershell_${ver}-1.deb_${arch}.deb"
    wget -q "https://github.com/PowerShell/PowerShell/releases/download/${tag}/powershell_${ver}-1.deb_${arch}.deb" -O "$deb" \
        || { rm -f "$deb"; err "download failed"; return 1; }
    apt_update || { rm -f "$deb"; return 1; }
    step "installing $deb"
    if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb"; then
        rm -f "$deb"
        err "failed to install $deb"
        return 1
    fi
    rm -f "$deb"
    have pwsh || { err "pwsh binary not found after install"; return 1; }
    ok "pwsh $(pwsh --version 2>/dev/null) — GitHub release ${tag}"
    muted "same package name as the apt repo — once Microsoft publishes the"
    muted "stable build for Ubuntu $os_id, regular apt upgrades track it."
}

install_python3() {
    banner "Python 3"
    apt_install "Python 3 toolchain" python3 python3-pip python3-venv python3-dev python-is-python3 || return 1
    have pip3 || { err "pip3 not found after install"; return 1; }
    ok "$(python3 --version) · $(pip3 --version 2>/dev/null | awk '{print $1, $2}')"
    muted "create virtual envs with: python3 -m venv ~/.venvs/<name>"
}

install_uv() {
    banner "uv / uvx"
    have curl || apt_install "curl prerequisite" curl || return 1
    step "running the official installer (astral.sh/uv/install.sh)"
    curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR="$HOME/.local/bin" sh \
        || { err "uv installer failed"; return 1; }
    if [[ -d "$HOME/.local/bin" && ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        export PATH="$HOME/.local/bin:$PATH"
    fi
    have uv  || { err "uv binary not found after install"; return 1; }
    have uvx || { err "uvx binary not found after install"; return 1; }
    ok "$(uv --version) · uvx $(uvx --version 2>/dev/null | awk '{print $2}')"
    muted "installed to ~/.local/bin — open a new shell or run: source ~/.local/bin/env"
}

install_git() {
    banner "Git"
    apt_install "Git" git || return 1
    have git || { err "git binary not found after install"; return 1; }
    ok "$(git --version)"
}

install_build_essential() {
    banner "Build tools"
    apt_install "build-essential" build-essential || return 1
    have gcc || { err "gcc not found after install"; return 1; }
    ok "$(gcc --version | head -1)"
}

install_cli_utils() {
    banner "CLI utilities"
    apt_install "CLI utilities" jq unzip zip fzf ripgrep tree htop || return 1
    have jq || { err "jq not found after install"; return 1; }
    ok "jq · unzip · zip · fzf · rg · tree · htop"
}

install_nodejs() {
    banner "Node.js LTS (NodeSource)"
    have curl || apt_install "curl prerequisite" curl || return 1
    step "NodeSource setup script (setup_lts.x)"
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - \
        || { err "NodeSource setup script failed"; return 1; }
    APT_UPDATED=1
    apt_install "Node.js (includes npm + corepack)" nodejs || return 1
    have node || { err "node binary not found after install"; return 1; }
    ok "node $(node --version) · npm v$(npm --version 2>/dev/null || echo '?')"
}

# ---------------------------------------------------------------------------
# apt history analysis
# ---------------------------------------------------------------------------
history_log_packages() { # → package names seen in Install: lines (sorted, unique)
    # NOTE: never call die() here — this runs inside $( ) subshells where
    # exit would only end the subshell. HISTORY_FILE is validated in main().
    if [[ -z "$HISTORY_FILE" ]]; then
        { cat /var/log/apt/history.log 2>/dev/null || true
          zcat /var/log/apt/history.log.*.gz 2>/dev/null || true; }
    elif [[ -r "$HISTORY_FILE" ]]; then
        cat "$HISTORY_FILE"
    fi | awk '
        /^Install:/ {
            sub(/^Install:[ \t]*/, "")
            gsub(/\([^)]*\)/, "")                  # strip "(ver)" / "(ver, automatic)"
            n = split($0, grp, ",")
            for (i = 1; i <= n; i++) {
                split(grp[i], pkg, ":")            # "pkg:arch" → "pkg"
                gsub(/^[ \t]+|[ \t]+$/, "", pkg[1])
                if (pkg[1] != "") print pkg[1]
            }
        }' | sort -u
}

history_detected_recipes() { # → recipe keys previously seen in the apt history (or installed locally)
    local hist key marker matched
    hist="$(history_log_packages)"
    for key in "${MENU_ORDER[@]}"; do
        matched=0
        if [[ -n "$hist" ]]; then
            # shellcheck disable=SC2086  # MARKERS may list several packages
            for marker in ${MARKERS[$key]}; do
                if grep -qx -- "$marker" <<<"$hist"; then matched=1; break; fi
            done
        fi
        # When inspecting the local system (no --history file), also detect
        # script-installed recipes that do not go through apt.
        if (( ! matched )) && [[ -z "$HISTORY_FILE" ]]; then
            case "$key" in
                k3s) have k3s && matched=1 ;;
                uv)  { have uv || [[ -x "$HOME/.local/bin/uv" ]]; } && matched=1 ;;
            esac
        fi
        (( matched )) && echo "$key"
    done
}

show_history() {
    local pkgs count detected
    pkgs="$(history_log_packages)"
    count="$(grep -c . <<<"${pkgs:-}" || true)"
    detected="$(history_detected_recipes | paste -sd' ' -)"
    hdr "apt history analysis"
    muted "source: ${HISTORY_FILE:-/var/log/apt/history.log + rotated logs}"
    info "$count package(s) found in install history."
    info "recipes detected as previously installed: ${detected:-none}"
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
choose_from_menu() { # → newly selected recipe keys, one per line
    local -a options=() preselected=() choose_args=() chosen_keys=()
    local -A display=() prechecked_map=()
    local key joined selection header

    for key in "${MENU_ORDER[@]}"; do
        display["$key"]="$key — ${RECIPES[$key]}"
        options+=("${display[$key]}")
    done

    while IFS= read -r key; do
        if [[ -n "$key" ]]; then
            preselected+=("${display[$key]}")
            prechecked_map["$key"]=1
        fi
    done < <(history_detected_recipes)

    joined=""
    if (( ${#preselected[@]} )); then
        printf -v joined '%s,' "${preselected[@]}"
        joined="${joined%,}"
    fi

    if [[ -z "$HISTORY_FILE" ]]; then
        header="$(gum style --bold 'Choose software to install')
space or x toggle · enter confirm · a select-all · esc cancel
[x] marks already-installed software — toggle new items to install them."
    else
        header="$(gum style --bold 'Choose software to install')
space or x toggle · enter confirm · a select-all · esc cancel
pre-checked entries were detected in $HISTORY_FILE."
    fi

    choose_args=(--no-limit --height "$(( ${#options[@]} + 2 ))" --header "$header")
    [[ -n "$joined" ]] && choose_args+=(--selected="$joined")

    local auto_toggle=0
    [[ -z "$HISTORY_FILE" ]] && auto_toggle=1

    selection="$(GUM_AUTO_TOGGLE_CURSOR="$auto_toggle" run_gum_choose "${choose_args[@]}" "${options[@]}")" \
        || die "selection cancelled."
    [[ -n "$selection" ]] || return 0

    mapfile -t chosen_keys < <(printf '%s\n' "$selection" | awk '{print $1}')

    for key in "${chosen_keys[@]}"; do
        # When running against the local system (no --history file), items that
        # started pre-checked [x] are already installed — only return newly
        # checked recipes so we don't reinstall existing software.
        if [[ -z "$HISTORY_FILE" && -n "${prechecked_map[$key]:-}" ]]; then
            continue
        fi
        printf '%s\n' "$key"
    done
}

list_recipes() {
    local key
    for key in "${MENU_ORDER[@]}"; do
        printf '%-18s %s\n' "$key" "${RECIPES[$key]}"
    done
}

usage() {
    cat <<'EOF'
02-install-software.sh — gum-powered software picker for a fresh WSL image.

Usage:
  ./02-install-software.sh                     interactive multi-select menu
  ./02-install-software.sh docker python3      install specific recipes directly
  ./02-install-software.sh --list              list available recipes
  ./02-install-software.sh --show-history      show apt-history preselect analysis
  ./02-install-software.sh --history FILE      preselect from an exported apt
                                               history log (old machine)
  ./02-install-software.sh --help              this help

Recipes are pre-checked in the menu when their marker package appears in the
apt history (local /var/log/apt/history.log* or the --history file).

Theme overrides (environment variables; term256 colour numbers or hex):
  THEME_PRIMARY   headings/banners      (default 212)
  THEME_SUCCESS   success messages      (default 46)
  THEME_ERROR     errors                (default 196)
  THEME_INFO      step/info messages    (default 39)
  THEME_MUTED     hints/footnotes       (default 245)
  THEME_CURSOR    menu cursor colour    (default 212)
  THEME_SELECTED  selected item colour  (default 46)
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local -a picks=() keys=() done_ok=() failed=()
    local key i suggestion

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)      usage; exit 0 ;;
            --list)         list_recipes; exit 0 ;;
            --show-history) show_history; exit 0 ;;
            --history)      [[ $# -ge 2 ]] || die "--history needs a file argument"
                            [[ -r "$2" ]] || die "cannot read --history file: $2"
                            HISTORY_FILE="$2"; shift 2 ;;
            -*)             die "unknown option: $1 (see --help)" ;;
            *)              picks+=("$1"); shift ;;
        esac
    done

    [[ $EUID -eq 0 ]] && die "run as your normal user (sudo is used where needed), not as root."
    have gum || die "gum is required — run ./01-install-gum.sh first."
    apply_gum_theme

    banner "WSL dev image · software installer"

    if (( ${#picks[@]} )); then
        # recipes given on the command line — explicit intent, no confirm needed
        for key in "${picks[@]}"; do
            [[ -n "${RECIPES[$key]:-}" ]] \
                || die "unknown recipe: '$key' (see ./02-install-software.sh --list)"
        done
        keys=("${picks[@]}")
    else
        mapfile -t keys < <(choose_from_menu)
    fi

    (( ${#keys[@]} )) || { muted "no new recipes selected — bye."; exit 0; }

    hdr "Selected ${#keys[@]} recipe(s)"
    if have gum; then
        { for key in "${keys[@]}"; do printf ' • %s\n' "$key — ${RECIPES[$key]}"; done; } \
            | gum style --border rounded --border-foreground "$THEME_PRIMARY" \
                --padding "0 1" --margin "0 1"
    else
        for key in "${keys[@]}"; do printf '  • %s — %s\n' "$key" "${RECIPES[$key]}"; done
    fi
    suggestion="$(history_detected_recipes | paste -sd' ' -)"
    if [[ -z "$HISTORY_FILE" ]]; then
        [[ -n "$suggestion" ]] && muted "already installed (skipped): $suggestion"
    else
        [[ -n "$suggestion" ]] && muted "apt history suggests: $suggestion"
    fi

    if (( ${#picks[@]} == 0 )); then
        gum confirm "Install the ${#keys[@]} selected recipe(s)?" \
            || die "aborted — nothing was installed."
    fi

    sudo -v || die "sudo access is required to install software."

    i=0
    for key in "${keys[@]}"; do
        i=$((i + 1))
        echo
        hdr "[$i/${#keys[@]}] ${RECIPES[$key]}"
        sudo -v 2>/dev/null || true
        if "install_${key//-/_}"; then
            done_ok+=("$key")
        else
            failed+=("$key")
        fi
    done

    echo
    banner "Summary"
    for key in "${done_ok[@]}"; do ok "$key"; done
    for key in "${failed[@]}";  do err "$key — check the output above"; done

    if (( ${#failed[@]} == 0 )); then
        ok "all ${#done_ok[@]} recipe(s) installed successfully 🎉"
        exit 0
    fi
    exit 1
}

main "$@"
