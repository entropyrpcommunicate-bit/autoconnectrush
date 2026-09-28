#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage="dist/macos"
app="$stage/Планировщик пар.app"
mkdir -p "$app/Contents/MacOS" dist/mac-objects
cp macos/Info.plist "$app/Contents/Info.plist"
for arch in arm64 x86_64; do
  xcrun swiftc macos/main.swift -target "$arch-apple-macos13.0" -O \
    -module-cache-path dist/mac-objects/cache \
    -o "dist/mac-objects/LessonPlanner-$arch" -framework Cocoa -framework WebKit
done
xcrun lipo -create dist/mac-objects/LessonPlanner-arm64 dist/mac-objects/LessonPlanner-x86_64 -output "$app/Contents/MacOS/LessonPlanner"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
"$app/Contents/MacOS/LessonPlanner" --self-test
cp macos/ИНСТРУКЦИЯ.md LICENSE "$stage/"
ditto -c -k --keepParent "$stage" dist/AutoConnectRush-macos-universal.zip
python3 - <<'PY'
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import hashlib
with ZipFile('dist/AutoConnectRush-macos-source.zip', 'w', ZIP_DEFLATED) as z:
    for p in [*Path('macos').glob('*'), Path('scripts/publish-macos.sh'), Path('LICENSE')]:
        z.write(p, str(p))
with open('dist/SHA256SUMS-macos.txt', 'w') as f:
    for p in sorted(Path('dist').glob('AutoConnectRush-macos-*.zip')):
        f.write(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n')
PY
