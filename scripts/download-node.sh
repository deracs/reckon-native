#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
node_version="24.21.0"
case "$(uname -m)" in
  arm64) node_arch="arm64" ;;
  x86_64) node_arch="x64" ;;
  *) echo "Unsupported macOS architecture" >&2; exit 1 ;;
esac
runtime_dir="$project_dir/.build/node-runtime"
archive="node-v${node_version}-darwin-${node_arch}.tar.gz"
mkdir -p "$runtime_dir"
cd "$runtime_dir"
curl --fail --silent --show-error --location --remote-name "https://nodejs.org/dist/v${node_version}/${archive}"
curl --fail --silent --show-error --location --output SHASUMS256.txt "https://nodejs.org/dist/v${node_version}/SHASUMS256.txt"
awk -v name="$archive" '$2 == name' SHASUMS256.txt > archive.sha256
test -s archive.sha256
shasum -a 256 --check archive.sha256
tar -xzf "$archive"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "RECKON_NODE_BINARY=$runtime_dir/node-v${node_version}-darwin-${node_arch}/bin/node" >> "$GITHUB_ENV"
  echo "RECKON_NODE_LICENSE=$runtime_dir/node-v${node_version}-darwin-${node_arch}/LICENSE" >> "$GITHUB_ENV"
fi
echo "Node runtime ready in $runtime_dir/node-v${node_version}-darwin-${node_arch}"
