#!/bin/sh
set -eu

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$project_dir/hawiian_rummy_scorekeeper"
output_dir="$(mktemp -d)"
trap 'rm -rf "$output_dir"' EXIT

xcrun --sdk macosx swiftc -D DEBUG -default-isolation MainActor \
    -target "$(uname -m)-apple-macosx26.0" -module-cache-path "$output_dir/modules" \
    "$source_dir/Models/GameModels.swift" \
    "$source_dir/Models/GroupModels.swift" \
    "$source_dir/Models/GroupGame.swift" \
    "$source_dir/Models/PlayerName.swift" \
    "$source_dir/Services/GameRules.swift" \
    "$source_dir/Services/GroupCloudStore.swift" \
    "$source_dir/Services/GroupCache.swift" \
    "$source_dir/Services/GroupRepository.swift" \
    "$source_dir/Services/GroupRoster.swift" \
    "$source_dir/Services/GroupRosterCloudStore.swift" \
    "$source_dir/Services/GroupsModel.swift" \
    "$source_dir/Services/GroupGameStore.swift" \
    "$source_dir/Services/GroupGameVerification.swift" \
    "$project_dir/Tests/GroupGameChecks.swift" \
    -o "$output_dir/GroupGameChecks"

"$output_dir/GroupGameChecks"
