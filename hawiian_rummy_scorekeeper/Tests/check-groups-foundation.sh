#!/bin/sh
set -eu

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$project_dir/hawiian_rummy_scorekeeper"
output_dir="$(mktemp -d)"
trap 'rm -rf "$output_dir"' EXIT

xcrun --sdk macosx swiftc -D DEBUG -default-isolation MainActor \
    -target "$(uname -m)-apple-macosx26.0" \
    "$source_dir/Models/GroupModels.swift" \
    "$source_dir/Models/PlayerName.swift" \
    "$source_dir/Services/GroupCache.swift" \
    "$source_dir/Services/GroupRepository.swift" \
    "$source_dir/Services/GroupRoster.swift" \
    "$source_dir/Services/GroupRosterCloudStore.swift" \
    "$source_dir/Services/GroupsModel.swift" \
    "$project_dir/Tests/GroupsFoundationChecks.swift" \
    -o "$output_dir/GroupsFoundationChecks"

"$output_dir/GroupsFoundationChecks"
