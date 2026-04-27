#!/usr/bin/env bash
# list-scripts.sh - List repo helper scripts with short descriptions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

describe_script() {
    local file=$1 ext line

    ext=${file##*.}
    case $ext in
        sh)
            line=$(grep -m1 -E '^# .+ - .+' "$file" | sed 's/^# //')
            ;;
        ts)
            line=$(grep -m1 -E '^// .+ - .+' "$file" | sed 's#^// ##')
            ;;
        *)
            if head -1 "$file" | grep -q '^#!.*\(sh\|bash\)'; then
                line=$(grep -m1 -E '^# .+ - .+' "$file" | sed 's/^# //')
            else
                line=""
            fi
            ;;
    esac

    if [[ -n $line ]]; then
        printf '%s' "$line"
    else
        printf '%s' "No description"
    fi
}

main() {
    printf 'Repo Scripts\n\n'
    find "$SCRIPT_DIR" -maxdepth 1 -type f | sort | while read -r file; do
        local_name=$(basename "$file")
        printf '  %-26s %s\n' "$local_name" "$(describe_script "$file")"
    done
}

main "$@"
