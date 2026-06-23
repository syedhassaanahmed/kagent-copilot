#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 10-install-tools.sh — idempotently install the CLI tools the demo needs.
#
#   kubectl, kind, helm        (always)
#   ollama                     (only when LLM_PROVIDER=ollama)
#   devtunnel, pac             (always; optional/non-fatal installers)
#
# Installer is chosen per OS: Homebrew on macOS, direct download on Linux/WSL2.
# A tool that is already on PATH is left untouched (non-destructive) and its
# version is reported. Re-running is a no-op.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_env_file
load_env

OS="$(detect_os)"
ARCH="$(detect_arch)"

# Pinned fallback versions used ONLY when a tool must be installed.
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.34.1}"
KIND_VERSION="${KIND_VERSION:-v0.32.0}"
HELM_VERSION="${HELM_VERSION:-v3.16.4}"

# Pick an install prefix we can write to (sudo only if needed).
BINDIR="/usr/local/bin"
SUDO=""
if [ ! -w "$BINDIR" ]; then
  if have_cmd sudo; then SUDO="sudo"; else BINDIR="$HOME/.local/bin"; mkdir -p "$BINDIR"; fi
fi

_download() { # url dest
  curl -fsSL "$1" -o "$2"
}

brew_install() { # pkg
  have_cmd brew || die "Homebrew required on macOS. Install from https://brew.sh and retry."
  brew list "$1" >/dev/null 2>&1 || brew install "$1"
}

install_kubectl() {
  if have_cmd kubectl; then ok "kubectl present: $(kubectl version --client 2>/dev/null | head -1)"; return; fi
  log "installing kubectl ${KUBECTL_VERSION}..."
  if [ "$OS" = macos ]; then brew_install kubernetes-cli; else
    local tmp; tmp="$(mktemp)"
    _download "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" "$tmp"
    chmod +x "$tmp"; $SUDO install -m 0755 "$tmp" "$BINDIR/kubectl"; rm -f "$tmp"
  fi
  ok "kubectl installed"
}

install_kind() {
  if have_cmd kind; then ok "kind present: $(kind version 2>/dev/null)"; return; fi
  log "installing kind ${KIND_VERSION}..."
  if [ "$OS" = macos ]; then brew_install kind; else
    local tmp; tmp="$(mktemp)"
    _download "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}" "$tmp"
    chmod +x "$tmp"; $SUDO install -m 0755 "$tmp" "$BINDIR/kind"; rm -f "$tmp"
  fi
  ok "kind installed"
}

install_helm() {
  if have_cmd helm; then ok "helm present: $(helm version --short 2>/dev/null)"; return; fi
  log "installing helm ${HELM_VERSION}..."
  if [ "$OS" = macos ]; then brew_install helm; else
    local tmp dir; tmp="$(mktemp -d)"
    _download "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" "$tmp/helm.tgz"
    tar -xzf "$tmp/helm.tgz" -C "$tmp"
    $SUDO install -m 0755 "$tmp/linux-${ARCH}/helm" "$BINDIR/helm"; rm -rf "$tmp"
  fi
  ok "helm installed"
}

install_ollama() {
  if have_cmd ollama; then ok "ollama present: $(ollama --version 2>/dev/null | head -1)"; return; fi
  log "installing ollama..."
  if [ "$OS" = macos ]; then
    brew_install ollama
  else
    curl -fsSL https://ollama.com/install.sh | sh
  fi
  ok "ollama installed"
}

install_devtunnel() {
  if have_cmd devtunnel; then ok "devtunnel present: $(devtunnel --version 2>/dev/null | head -1)"; return; fi
  log "installing devtunnel..."
  if [ "$OS" = macos ]; then
    if have_cmd brew && brew install --cask devtunnel; then
      ok "devtunnel installed"
    else
      warn "could not install devtunnel with Homebrew; install manually from https://aka.ms/DevTunnelCli"
    fi
  else
    if curl -sL https://aka.ms/DevTunnelCliInstall | bash; then
      if have_cmd devtunnel; then
        ok "devtunnel installed"
      else
        warn "devtunnel installed but is not on PATH; add ~/.local/bin or the reported install directory to PATH"
      fi
    else
      warn "could not install devtunnel; install manually from https://aka.ms/DevTunnelCli"
    fi
  fi
}

install_pac() {
  if have_cmd pac; then ok "pac present: $(pac --version 2>/dev/null | head -1)"; return; fi
  if have_cmd dotnet; then
    log "installing pac..."
    dotnet tool install --global Microsoft.PowerApps.CLI.Tool || dotnet tool update --global Microsoft.PowerApps.CLI.Tool || true
    if have_cmd pac; then
      ok "pac installed"
    else
      warn "pac installed but is not on PATH; add ~/.dotnet/tools to PATH"
    fi
  else
    warn "pac requires the .NET SDK; install .NET 8+ then re-run, or install pac manually per https://aka.ms/PowerPlatformCLI"
  fi
}

log "installing tools for ${OS}/${ARCH} (prefix: ${BINDIR})"
install_kubectl
install_kind
install_helm
if [ "${LLM_PROVIDER:-ollama}" = "ollama" ]; then
  install_ollama
else
  log "LLM_PROVIDER=${LLM_PROVIDER} — skipping ollama install"
fi
install_devtunnel
install_pac

echo
ok "tool versions:"
printf '  kubectl : %s\n' "$(kubectl version --client 2>/dev/null | head -1 || echo missing)"
printf '  kind    : %s\n' "$(kind version 2>/dev/null || echo missing)"
printf '  helm    : %s\n' "$(helm version --short 2>/dev/null || echo missing)"
have_cmd ollama && printf '  ollama  : %s\n' "$(ollama --version 2>/dev/null | head -1)"
have_cmd devtunnel && printf '  devtunnel: %s\n' "$(devtunnel --version 2>/dev/null | head -1)"
have_cmd pac && printf '  pac     : %s\n' "$(pac --version 2>/dev/null | head -1)"
ok "install-tools complete"
