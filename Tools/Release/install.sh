#!/bin/bash
# Installs Crawlspace, or brings an existing copy up to date. After this it
# updates itself.
#
#   curl -fsSL https://raw.githubusercontent.com/drkge/crawlspace/main/Tools/Release/install.sh | bash
#
# Everything is downloaded with curl, which doesn't mark files as quarantined, so macOS doesn't
# ask anyone to approve the app in System Settings.
set -euo pipefail

name="Crawlspace"
bundle_id="io.github.drkge.crawlspace"
repo="drkge/crawlspace"
asset="Crawlspace.app.tar.gz"
api="https://api.github.com/repos/$repo"
apps="$HOME/Applications"
app="$apps/$name.app"
support="$HOME/Library/Application Support/$name"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '%s couldn'"'"'t be installed: %s\n' "$name" "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "it runs on macOS only."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 26 ] || fail "it needs macOS 26 or later (this Mac has $(sw_vers -productVersion))."
case "$(uname -m)" in
    arm64) arch=arm64 ;;
    x86_64) arch=x64 ;;
    *) fail "unknown processor $(uname -m)." ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

say "Finding the latest version…"
curl -fsS -H "Accept: application/vnd.github+json" "$api/releases/latest" -o "$work/release.json" \
    || fail "GitHub didn't answer, or there's no release yet."

# The release JSON is read with plutil, which every Mac has, rather than python or jq.
plutil -convert xml1 -o "$work/release.plist" "$work/release.json"
field() { /usr/libexec/PlistBuddy -c "Print :$1" "$work/release.plist" 2>/dev/null; }
version=$(field tag_name | sed 's/^v//')
asset_url=""
asset_digest=""
runtime_name=""
runtime_url=""
runtime_digest=""
index=0
while asset_name=$(field "assets:$index:name"); do
    case "$asset_name" in
        "$asset")
            asset_url=$(field "assets:$index:browser_download_url")
            asset_digest=$(field "assets:$index:digest") ;;
        lighthouse-runtime-*-"$arch".tar.gz)
            runtime_name=$asset_name
            runtime_url=$(field "assets:$index:browser_download_url")
            runtime_digest=$(field "assets:$index:digest") ;;
    esac
    index=$((index + 1))
done
[ -n "$asset_url" ] || fail "the latest release ($version) has no app to download."

# Downloads a release asset and checks it against the SHA-256 GitHub publishes for it.
download() {
    local url=$1 digest=$2 output=$3
    curl -fsSL "$url" -o "$output" \
        || fail "the download failed."
    [ -n "$digest" ] || fail "GitHub gave no checksum for the download."
    echo "${digest#sha256:}  $output" | shasum -a 256 -c - >/dev/null || fail "the download didn't match its checksum."
}

say "Downloading ${name} ${version}…"
download "$asset_url" "$asset_digest" "$work/app.tar.gz"
mkdir -p "$work/app"
tar -xzf "$work/app.tar.gz" -C "$work/app"
codesign --verify --deep --strict "$work/app/$name.app" || fail "the app's signature didn't check out."

# A running copy lets go of its files and its port first.
if pgrep -qf "$name.app/Contents/MacOS/Crawlspace"; then
    say "Closing the running copy…"
    osascript -e "quit app id \"$bundle_id\"" >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do pgrep -qf "$name.app/Contents/MacOS/Crawlspace" || break; sleep 0.2; done
fi

mkdir -p "$apps"
rm -rf "$app.installing"
mv "$work/app/$name.app" "$app.installing"
rm -rf "$app"
mv "$app.installing" "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" >/dev/null 2>&1 || true

binary="$app/Contents/MacOS/Crawlspace"

# Crawls, settings and tokens live here, readable by this account only.
mkdir -p "$support"
chmod 700 "$support"

# Lighthouse's runtime now, so speed reports work from the first crawl. The app keeps it current.
if [ -n "$runtime_url" ]; then
    runtime_version=${runtime_name#lighthouse-runtime-}
    runtime_version=${runtime_version%-"$arch".tar.gz}
    toolchain="$support/Toolchain"
    if [ "$(readlink "$toolchain/current" 2>/dev/null)" != "$runtime_version" ]; then
        say "Downloading Lighthouse…"
        download "$runtime_url" "$runtime_digest" "$work/runtime.tar.gz"
        mkdir -p "$toolchain/$runtime_version.installing"
        tar -xzf "$work/runtime.tar.gz" -C "$toolchain/$runtime_version.installing"
        rm -rf "$toolchain/$runtime_version"
        mv "$toolchain/$runtime_version.installing" "$toolchain/$runtime_version"
        ln -sfn "$runtime_version" "$toolchain/current"
    fi
fi

# `crawlspace` on the command line, where the user can write without sudo.
link_dir=""
for candidate in /usr/local/bin /opt/homebrew/bin; do
    if [ -d "$candidate" ] && [ -w "$candidate" ]; then link_dir=$candidate; break; fi
done
if [ -z "$link_dir" ]; then
    link_dir="$HOME/.local/bin"
    mkdir -p "$link_dir"
fi
ln -sf "$binary" "$link_dir/crawlspace"
case ":$PATH:" in
    *":$link_dir:"*) ;;
    *) echo "  Add $link_dir to your PATH to use the crawlspace command in Terminal." ;;
esac

say "$name $version is installed in $apps."
open "$app"
echo "It's running in the menu bar (the ant) and opening in your browser. From now on it updates itself."
