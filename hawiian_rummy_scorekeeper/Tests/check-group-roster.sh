#!/bin/sh
set -eu

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$project_dir/hawiian_rummy_scorekeeper"
output_dir="$(mktemp -d)"
trap 'rm -rf "$output_dir"' EXIT

xcrun --sdk macosx swiftc -D DEBUG -default-isolation MainActor \
    -target "$(uname -m)-apple-macosx26.0" -module-cache-path "$output_dir/modules" \
    "$source_dir/Models/GroupModels.swift" \
    "$source_dir/Models/PlayerName.swift" \
    "$source_dir/Services/GroupRoster.swift" \
    "$source_dir/Services/GroupRosterCloudStore.swift" \
    "$project_dir/Tests/GroupRosterChecks.swift" \
    -o "$output_dir/GroupRosterChecks"

"$output_dir/GroupRosterChecks"
