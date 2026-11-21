#!/bin/sh
set -eu

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$project_dir/hawiian_rummy_scorekeeper"
output_dir="$(mktemp -d)"
trap 'rm -rf "$output_dir"' EXIT

xcrun --sdk macosx swiftc -default-isolation MainActor \
    -target "$(uname -m)-apple-macosx26.0" \
    "$source_dir/Models/GameModels.swift" \
    "$source_dir/Services/GameRules.swift" \
    "$source_dir/Services/LifetimeRecords.swift" \
    "$source_dir/Services/PersonalHistoryDeletion.swift" \
    "$project_dir/Tests/PersonalDeletionChecks.swift" \
    -o "$output_dir/PersonalDeletionChecks"

"$output_dir/PersonalDeletionChecks"
