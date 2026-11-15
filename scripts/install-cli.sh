#!/bin/zsh
set -euo pipefail
# Explicit user action only: create a symlink, never edit shell configuration or use sudo.
app_path="${1:-${0:A:h:h}/build/Meeting Intelligence.app}"
cli_path="$app_path/Contents/MacOS/meeting"
bin_path="$HOME/.local/bin"
if (( $# > 1 )); then
  print -u2 'Usage: scripts/install-cli.sh [path/to/Meeting Intelligence.app]'
  exit 2
fi
if [[ ! -x "$cli_path" ]]; then
  print -u2 "CLI not found: $cli_path"
  print -u2 'Build the app first with scripts/build-app.sh.'
  exit 3
fi
cli_path="${cli_path:A}"
mkdir -p "$bin_path"
if [[ -e "$bin_path/meeting" || -L "$bin_path/meeting" ]]; then
  if [[ -L "$bin_path/meeting" && "${bin_path}/meeting" -ef "$cli_path" ]]; then
    print "Already installed: $bin_path/meeting"
    exit 0
  fi
  print -u2 "Refusing to replace existing entry: $bin_path/meeting"
  print -u2 'Remove or move that entry explicitly, then rerun this script.'
  exit 5
fi
ln -s "$cli_path" "$bin_path/meeting"
print "Installed $bin_path/meeting -> $cli_path"
if (( ! ${path[(Ie)$bin_path]} )); then
  print 'Add this to your shell configuration if needed:'
  print '  export PATH="$HOME/.local/bin:$PATH"'
fi
