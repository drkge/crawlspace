#!/bin/bash
# Builds "Crawlspace.app" and the tarball a release publishes.
#
#   Tools/Release/make-app.sh [version] [build-number]
#
# The app is a universal binary with the web UI built into it, ad-hoc signed. That is enough:
# copies arrive by curl or by the app's own updater, never through a browser, so Gatekeeper's
# quarantine never applies and no Developer ID is needed.
set -euo pipefail

cd "$(dirname "$0")/../.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

name="Crawlspace"
version=${1:-2.0.0-dev}
build=${2:-1}
commit=$(git rev-parse --short HEAD 2>/dev/null || echo dev)
package=Packages/CrawlspaceKit
generated=(
    "$package/Sources/WebAssets/Generated.swift"
    "$package/Sources/Server/Version.swift"
)

# The UI and version stamp are written into the source tree for the build, then put back, so a
# local release build leaves git clean.
restore() { git checkout -- "${generated[@]}" 2>/dev/null || true; }
trap restore EXIT

echo "Building the web UI…"
(cd Web && npm ci --no-audit --no-fund >/dev/null && npm run build >/dev/null)
swift Tools/Release/embed-web.swift

cat > "$package/Sources/Server/Version.swift" <<SWIFT
/// Which build this is. CI rewrites this file for each release; a local build says "dev".
public enum AppVersion {
    public static let current = "$version"
    public static let commit = "$commit"
}
SWIFT

echo "Building $name $version ($commit) for Apple Silicon and Intel…"
swift build -c release --package-path "$package" --product crawlspace --arch arm64 --arch x86_64 >/dev/null
binary="$(swift build -c release --package-path "$package" --arch arm64 --arch x86_64 --show-bin-path)/crawlspace"
echo "Architectures: $(lipo -archs "$binary")"

app="dist/$name.app"
archive="dist/Crawlspace.app.tar.gz"
rm -rf "$app" "$archive"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Crawlspace"
cp Tools/Release/Resources/*.icns "$app/Contents/Resources/"
# Crawlspace's own licence, and those of everything built into it.
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
python3 Tools/Release/make-notices.py "$app/Contents/Resources/ThirdPartyNotices.txt" >/dev/null
sed -e "s/@VERSION@/$version/" -e "s/@BUILD@/$build/" Tools/Release/Info.plist > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null

codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"

tar -C dist -czf "$archive" "$name.app"
echo "Wrote $archive ($(du -h "$archive" | cut -f1))"
