#!/bin/bash
set -e

# deva Version Consistency Checker
# Validates that all version references are consistent

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

error() {
    echo -e "${RED}❌ $1${NC}" >&2
}

success() {
    echo -e "${GREEN}✅ $1${NC}"
}

warning() {
    echo -e "${YELLOW}⚠️ $1${NC}"
}

get_deva_version() {
    grep 'VERSION=' deva.sh | head -1 | sed 's/.*VERSION="\([^"]*\)".*/\1/'
}

get_changelog_version() {
    grep -E '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md | head -1 | sed 's/.*\[\([^]]*\)\].*/\1/'
}

get_git_latest_tag() {
    git tag --list --sort=-version:refname | head -1 | sed 's/^v//'
}

check_consistency() {
    local deva_version=$(get_deva_version)
    local changelog_version=$(get_changelog_version)
    local git_version=$(get_git_latest_tag)
    
    echo "Version Consistency Check"
    echo "========================="
    echo "deva.sh:      $deva_version"
    echo "CHANGELOG.md:   $changelog_version"
    echo "Latest git tag: $git_version"
    echo ""
    
    local issues=0
    
    if [[ "$deva_version" != "$changelog_version" ]]; then
        error "Version mismatch: deva.sh ($deva_version) != CHANGELOG.md ($changelog_version)"
        issues=$((issues + 1))
    else
        success "deva.sh and CHANGELOG.md versions match"
    fi
    
    if [[ "$deva_version" != "$git_version" ]]; then
        if [[ "$deva_version" > "$git_version" ]]; then
            warning "deva.sh version ($deva_version) is newer than latest tag ($git_version) - this is expected for unreleased versions"
        else
            error "deva.sh version ($deva_version) is older than latest tag ($git_version)"
            issues=$((issues + 1))
        fi
    else
        success "deva.sh version matches latest git tag"
    fi
    
    echo ""
    
    if [[ $issues -eq 0 ]]; then
        success "All versions are consistent!"
        return 0
    else
        error "Found $issues version consistency issue(s)"
        echo ""
        echo "To fix:"
        echo "  1. Use ./scripts/release.sh <version> for new releases"
        echo "  2. Or manually update deva.sh and CHANGELOG.md to match"
        return 1
    fi
}

main() {
    if [[ ! -f "deva.sh" ]] || [[ ! -f "CHANGELOG.md" ]]; then
        error "Must be run from deva root directory"
        exit 1
    fi
    
    check_consistency
}

main "$@"