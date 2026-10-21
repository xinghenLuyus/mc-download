#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive_root="$project_root/orther"
move_generated() {
  local source_path="$project_root/$1"
  local target_path="$archive_root/$2"
  if [[ ! -e "$source_path" && ! -L "$source_path" ]]; then return; fi
  if [[ -e "$target_path" || -L "$target_path" ]]; then
    target_path="$target_path-$(date -u +%Y%m%d-%H%M%S)-$$"
  fi
  mkdir -p "$(dirname "$target_path")"
  mv "$source_path" "$target_path"
}
move_generated .dart_tool cache/.dart_tool
move_generated .flutter-plugins-dependencies cache/.flutter-plugins-dependencies
move_generated .flutter-plugins cache/.flutter-plugins
move_generated .packages cache/.packages
move_generated .idea cache/.idea
move_generated build build
move_generated coverage cache/coverage
move_generated .upstream upstream
move_generated local-data local-data
move_generated windows/flutter/ephemeral cache/windows-flutter-ephemeral
for module in "$project_root"/*.iml; do
  [[ -e "$module" ]] || continue
  move_generated "$(basename "$module")" "cache/$(basename "$module")"
done
printf '%s\n' 'Generated files archived under orther/.'
