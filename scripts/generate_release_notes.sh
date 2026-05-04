#!/bin/zsh
set -euo pipefail

current_tag="${1:?Usage: $0 <tag> <version> <output>}"
version="${2:?Usage: $0 <tag> <version> <output>}"
output_path="${3:?Usage: $0 <tag> <version> <output>}"

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root_dir"

release_date="$(date -u +%Y-%m-%d)"
mkdir -p "$(dirname "$output_path")"

previous_tag="$(git tag --sort=-version:refname | awk -v current="$current_tag" '$0 != current { print; exit }')"

if [[ -n "$previous_tag" ]]; then
  range="${previous_tag}..${current_tag}"
else
  range="${current_tag}"
fi

sections=("Features" "Fixes" "Performance" "Documentation" "Maintenance" "Other Changes")
typeset -A section_files
for section in "${sections[@]}"; do
  section_files[$section]="$(mktemp)"
done

while IFS=$'\t' read -r sha subject; do
  [[ -z "$sha" ]] && continue
  [[ "$subject" == Merge\ * ]] && continue

  commit_type="other"
  summary="$subject"
  if [[ "$subject" =~ '^([a-z]+)(\([^)]+\))?:[[:space:]]*(.+)$' ]]; then
    commit_type="${match[1]}"
    summary="${match[3]}"
  fi

  case "$commit_type" in
    feat) section="Features" ;;
    fix) section="Fixes" ;;
    perf) section="Performance" ;;
    docs) section="Documentation" ;;
    ci|build|chore|test|refactor) section="Maintenance" ;;
    *) section="Other Changes" ;;
  esac

  printf -- '- %s (`%s`)\n' "$summary" "$sha" >> "${section_files[$section]}"
done < <(git log --first-parent --reverse --format='%h%x09%s' "$range")

{
  printf '# Switcheroo %s\n\n' "$version"
  printf 'Released on %s.\n\n' "$release_date"
  printf "## What's Changed\n\n"

  for section in "${sections[@]}"; do
    if [[ -s "${section_files[$section]}" ]]; then
      printf '### %s\n\n' "$section"
      cat "${section_files[$section]}"
      printf '\n'
    fi
  done

  if [[ -n "$previous_tag" ]]; then
    printf '## Full Changelog\n\n'
    printf '[%s...%s](https://github.com/%s/compare/%s...%s)\n' \
      "$previous_tag" "$current_tag" "$GITHUB_REPOSITORY" "$previous_tag" "$current_tag"
  fi
} > "$output_path"

for file_path in "${(@v)section_files}"; do
  rm -f "$file_path"
done
