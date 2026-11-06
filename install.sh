#!/usr/bin/env sh
# xenon installer for macOS / linux / git bash. run it from the xenon folder:  sh install.sh
# it: checks rokit, installs lune (rokit.toml), adds bin/ to PATH in your shell profile,
# builds + installs the studio plugin. run it again any time (after git pull) to update.
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$ROOT/bin"

step() { printf '\n> %s\n' "$1"; }
ok() { printf '  ok  %s\n' "$1"; }
die() { printf '  !!  %s\n' "$1"; exit 1; }

echo "xenon installer"
echo "folder: $ROOT"

step "rokit"
command -v rokit >/dev/null 2>&1 || {
	echo "  rokit is not installed. install it, open a new terminal, run this again:"
	echo "    https://github.com/rojo-rbx/rokit#installation"
	die "rokit missing"
}
ok "$(rokit --version)"

step "lune (from rokit.toml)"
cd "$ROOT"
rokit install --no-trust-check || die "rokit install failed"
ok "$(lune --version)" || die "lune does not run"

step "PATH"
chmod +x "$BIN/xenon"
case ":$PATH:" in
	*":$BIN:"*) ok "already on PATH: $BIN" ;;
	*)
		PROFILE="$HOME/.profile"
		[ -n "$ZSH_VERSION" ] || [ "$(basename "${SHELL:-}")" = "zsh" ] && PROFILE="$HOME/.zshrc"
		[ -f "$HOME/.bashrc" ] && [ "$(basename "${SHELL:-}")" = "bash" ] && PROFILE="$HOME/.bashrc"
		LINE="export PATH=\"\$PATH:$BIN\""
		if ! grep -qsF "$LINE" "$PROFILE"; then
			printf '\n# xenon\n%s\n' "$LINE" >> "$PROFILE"
		fi
		ok "added to $PROFILE"
		PATH="$PATH:$BIN"
		;;
esac

step "studio plugin"
"$BIN/xenon" build || die "plugin build failed"

step "check"
ok "$("$BIN/xenon" version)"

echo
echo "done. next:"
echo "  1. open a NEW terminal (so PATH is fresh)"
echo "  2. restart Roblox Studio (loads the plugin)"
echo "  3. new game:       xenon init my-game"
echo "     existing game:  cd your-game-folder && xenon serve"
