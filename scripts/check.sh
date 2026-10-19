#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
swift run surge-guard-tests
swift build -c release -Xswiftc -warnings-as-errors
.build/release/surge-guard validate examples/enhanced.json
.build/release/surge-guard validate examples/routes.json
.build/release/surge-guard --help
.build/release/surge-guard install --help
.build/release/surge-gate --help
sh -n scripts/install-user.sh
sh -n integrations/swiftbar/surge-guard.5s.sh
git diff --check
