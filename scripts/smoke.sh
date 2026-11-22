#!/bin/bash
# End-to-end smoke check of the pieces the IDE depends on.
#
# Compiles and runs a real C++ program through the same BuildKit service the app
# uses, and verifies diagnostics parsing and clang-format integration when
# available. Exits non-zero on the first failure.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"
PRODUCTS="$BUILD_DIR/Build/Products/Debug"
FRAMEWORKS="$PRODUCTS"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ridecpp-smoke.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

echo "== RideCPP smoke check =="

# 1. Compiler availability, via the same discovery path the app uses.
COMPILER="$(command -v clang++ || true)"
[ -n "$COMPILER" ] || fail "no clang++ on PATH"
pass "compiler found: $COMPILER ($("$COMPILER" --version | head -1))"

# 2. A real compile + run through BuildKit.
cat > "$WORK/main.cpp" <<'CPP'
#include <iostream>
#include <vector>
int main() {
    std::vector<int> values{1, 2, 3};
    int sum = 0;
    for (int value : values) { sum += value; }
    std::cout << "ridecpp-smoke:" << sum << std::endl;
    return 0;
}
CPP

cat > "$WORK/smoke.swift" <<'SWIFT'
import Foundation
import BuildKit

let source = CommandLine.arguments[1]
let binary = CommandLine.arguments[2]
let request = BuildRequest(action: .run,
                           sourcePath: source,
                           sourceDisplayName: "main.cpp",
                           compilerPath: CommandLine.arguments[3],
                           standard: "c++17",
                           outputPath: binary,
                           workingDirectory: (source as NSString).deletingLastPathComponent)
let service = BuildService(scratchDirectory: URL(fileURLWithPath: (binary as NSString).deletingLastPathComponent))
var output = ""
var succeeded = false
var sawDiagnostics = false
let semaphore = DispatchSemaphore(value: 0)

Task {
    for await event in service.perform(request) {
        switch event {
        case .runOutput(let text):
            output += text
        case .compilerOutput:
            break
        case .diagnostics(let parsed):
            sawDiagnostics = !parsed.isEmpty
        case .finished(_, let ok):
            succeeded = ok
        default:
            break
        }
    }
    semaphore.signal()
}
semaphore.wait()

if !succeeded {
    FileHandle.standardError.write(Data("build did not succeed\n".utf8))
    exit(2)
}
if !output.contains("ridecpp-smoke:6") {
    FileHandle.standardError.write(Data("unexpected program output: \(output)\n".utf8))
    exit(3)
}
if sawDiagnostics {
    FileHandle.standardError.write(Data("unexpected diagnostics for valid program\n".utf8))
    exit(4)
}
print("ridecpp-smoke:6")
SWIFT

swiftc -module-cache-path "$BUILD_DIR/ModuleCache" \
    -sdk "$(xcrun --show-sdk-path)" \
    -target arm64-apple-macosx14.0 \
    -F "$FRAMEWORKS" -framework BuildKit \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    "$WORK/smoke.swift" -o "$WORK/smoke" 2>/dev/null \
  || fail "could not build the Swift smoke harness"

"$WORK/smoke" "$WORK/main.cpp" "$WORK/program" "$COMPILER" > "$WORK/smoke.log" 2>&1 \
  || { cat "$WORK/smoke.log"; fail "BuildKit build/run of a real program failed"; }
grep -q "ridecpp-smoke:6" "$WORK/smoke.log" || fail "program output mismatch"
pass "BuildKit compiled and ran a real C++ program"

# 3. Compiler diagnostics for a broken program.
cat > "$WORK/broken.cpp" <<'CPP'
int main() {
    return undefined_symbol;
}
CPP
if "$COMPILER" -std=c++17 -c "$WORK/broken.cpp" -o "$WORK/broken.o" 2> "$WORK/broken.err"; then
    fail "broken program unexpectedly compiled"
fi
grep -Eq 'error:' "$WORK/broken.err" || fail "compiler did not emit an error"
pass "compiler reports diagnostics for broken code"

# 4. clang-format, when installed.
FORMATTER="$(xcrun -f clang-format 2>/dev/null || true)"
if [ -n "$FORMATTER" ] && [ -x "$FORMATTER" ]; then
    printf 'int  main(){int x=1;return  0;}\n' > "$WORK/messy.cpp"
    "$FORMATTER" -style=LLVM "$WORK/messy.cpp" > "$WORK/formatted.cpp"
    grep -q 'int x = 1;' "$WORK/formatted.cpp" || fail "clang-format output unexpected"
    pass "clang-format available and working ($FORMATTER)"
else
    echo "  skip: clang-format not installed"
fi

# 5. The app bundle exists and is launchable.
APP="$PRODUCTS/RideCPP.app"
[ -d "$APP" ] || fail "RideCPP.app missing (run make build first)"
[ -x "$APP/Contents/MacOS/RideCPP" ] || fail "RideCPP executable missing"
[ -d "$APP/Contents/Frameworks/EditorCore.framework" ] || fail "EditorCore.framework not embedded"
[ -d "$APP/Contents/Frameworks/BuildKit.framework" ] || fail "BuildKit.framework not embedded"
[ -d "$APP/Contents/Resources/zh-Hans.lproj" ] || fail "Chinese localization missing"
[ -d "$APP/Contents/Resources/en.lproj" ] || fail "English localization missing"
[ -f "$APP/Contents/Resources/AppIcon.icns" ] || fail "app icon missing"
[ -f "$APP/Contents/Resources/Assets.car" ] || fail "compiled asset catalog missing"
pass "app bundle complete (frameworks, localizations, icon)"

echo "== all smoke checks passed =="
