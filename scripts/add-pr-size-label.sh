#!/bin/bash
#---------------------------------------------------------------------
# Description: FIXME.
#
# Concept inspired by the k8s GH plugin to add the same labels:
#
# https://github.com/kubernetes/test-infra/blob/master/prow/plugins/size/size.go
#---------------------------------------------------------------------

script_name=${0##*/}

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

[ -n "${DEBUG:-}" ] && set -o xtrace

readonly label_prefix="size/"

# Ranges that are used to determine which sizing label should be
# applied to a PR.
#
# The range value must be in one of the following formats:
#
# - "<maximum" (any value less than the specified limit).
# - "minimum-maximum" (value between the specified bounds).
# - ">minimum" (any value greater than the specified limit).
#
# Notes:
#
# - The values specified here are arbitrary and may need tweaking
#   (or overriding with the appropriate environment variable).
# - The ranges must not overlap.
readonly default_tiny_range='<10'
readonly default_small_range='10-49'
readonly default_medium_range='50-100'
readonly default_large_range='101-500'
readonly default_huge_range='>500'

## Allow the default ranges to be overriden by environment variables.
KATA_PR_SIZE_RANGE_TINY="${KATA_PR_SIZE_RANGE_TINY:-$default_tiny_range}"
KATA_PR_SIZE_RANGE_SMALL="${KATA_PR_SIZE_RANGE_SMALL:-$default_small_range}"
KATA_PR_SIZE_RANGE_MEDIUM="${KATA_PR_SIZE_RANGE_MEDIUM:-$default_medium_range}"
KATA_PR_SIZE_RANGE_LARGE="${KATA_PR_SIZE_RANGE_LARGE:-$default_large_range}"
KATA_PR_SIZE_RANGE_HUGE="${KATA_PR_SIZE_RANGE_HUGE:-$default_huge_range}"

typeset -A size_ranges

# Hash of labels and ranges uses to determine which label
# should be applied to a PR.
#
# key: Label suffix to add to PR if it matches the "size" specified
#  by the value.
# value: Size range.
size_ranges=(
    [tiny]="$KATA_PR_SIZE_RANGE_TINY"
    [small]="$KATA_PR_SIZE_RANGE_SMALL"
    [medium]="$KATA_PR_SIZE_RANGE_MEDIUM"
    [large]="$KATA_PR_SIZE_RANGE_LARGE"
    [huge]="$KATA_PR_SIZE_RANGE_HUGE"
)

# Protect against the scenario where diffstat(1) is internationalised.
export LC_ALL="C"
export LANG="C"

info()
{
    echo "INFO: $*"
}

die()
{
    echo >&2 "ERROR: $*"
    exit 1
}

setup()
{
    local cmds=()

    cmds+=("diffstat")
    cmds+=("gh")

    local cmd

    local ret

    for cmd in "${cmds[@]}"
    do
        { command -v "$cmd" &>/dev/null; ret=$?; } || true
        [ "$ret" -eq 0 ] || die "need command '$cmd'"
    done

    local vars=()

    # FIXME: TESTING
    #vars+=("GITHUB_USER")
    vars+=("GITHUB_TOKEN")

    local var

    for var in "${vars[@]}"
    do
        local value=$(printenv "$var" || true)
        [ -n "${value}" ] || die "need to set '$var'"
    done

    # Set non interactive mode
    gh config set prompt disabled
}

# Return an integer representing the "size" of a PR
# (where size really means "amount of change")
get_pr_size()
{
    local pr="${1:-}"
    [ -z "$pr" ] && die "need PR number"

    local stats

    # Example output showing the diffstat(1) format :
    #
    # "99 files changed, 12345 insertions(+), 987 deletions(-)"
    # "1 file changed, 1 insertion(+)"
    stats=$(gh pr diff "$pr" | diffstat -s)

    local additions
    local deletions

    additions=$(echo "$stats" |\
        grep -Eo '[0-9][0-9]* insertions?' |\
        awk '{print $1}' \
        || echo "0")

    deletions=$(echo "$stats" |\
        grep -Eo "[0-9][0-9]* deletions?" |\
        awk '{print $1}' \
        || echo "0")

    grep -q "^[0-9][0-9]*$" <<< "$additions" || \
        die "invalid additions: '$additions'"

    grep -q "^[0-9][0-9]*$" <<< "$deletions" || \
        die "invalid deletions: '$deletions'"

    local total
    total=$(( additions + deletions ))

    echo "$total"
}

get_label_to_add()
{
    local size="${1:-}"
    [ -z "$size" ] && die "need size value"

    local label

    for label in "${!size_ranges[@]}"
    do
        local range

        range="${size_ranges[$label]}"

        local value

        if grep -q '^<[0-9][0-9]*$' <<< "$range"
        then
            # Handle lower bound
            value=$(echo "$range"|sed 's/^<//g')

            (( size < value )) && \
            printf "%s%s" "$label_prefix" "$label" && \
            return 0
        elif grep -q '^>[0-9][0-9]*$' <<< "$range"
        then
            # Handle upper bound
            value=$(echo "$range"|sed 's/^>//g')

            (( size > value )) && \
            printf "%s%s" "$label_prefix" "$label" && \
            return 0
        elif grep -q '^[0-9][0-9]*-[0-9][0-9]*$' <<< "$range"
        then
            # Handle range
            local from
            local to

            from=$(echo "$range"|cut -d'-' -f1)
            to=$(echo "$range"|cut -d'-' -f2)

            (( from > to )) && die "invalid from/to range: '$range'"

            (( size > from )) && \
            (( size < to )) && \
            printf "%s%s" "$label_prefix" "$label" && \
            return 0
        else
            die "invalid range format: '$range'"
        fi
    done
}

handle_pr_labels()
{
    local pr="${1:-}"
    [ -z "$pr" ] && die "need PR number"

    local label="${2:-}"
    [ -z "$label" ] && die "need label to add"

    existing_size_labels=$(gh pr view "$pr" |\
        grep '^labels:' |\
        cut -d: -f2- |\
        tr -d '\t' |\
        tr ',' '\n' |\
        sed 's/^ *//g' |\
        grep "^${label_prefix}" \
        || true)

    local existing

    local add_label_args=""
    local rm_label_args=""

    add_label_args="--add-label '$label'"

    for existing in $existing_size_labels
    do
        # The PR already has the correct label, so ignore that one.
        [ "$existing" = "$label" ] && add_label_args="" && continue

        rm_label_args+=" --remove-label '$existing'"
    done

    # The PR is already labeled correctly and has no additional sizing
    # labels.
    [ -z "$add_label_args" ] && \
    [ -z "$rm_label_args" ] && \
    echo "::debug::PR $pr already labeled" && \
    return 0

    local pr_url

    # Update the PR to remove any old sizing labels and add the
    # correct new one.
    pr_url=$(eval gh pr edit \
        "$pr" \
        "$add_label_args" \
        "$rm_label_args")

    echo "::debug::Added label '$label' to PR $pr ($pr_url)"
}

handle_pr()
{
    local pr="${1:-}"
    [ -z "$pr" ] && die "need PR number"

    local size
    local label

    size=$(get_pr_size "$pr")

    echo "::debug::PR $pr size: $size"

    label=$(get_label_to_add "$size")

    echo "::debug::PR $pr label to add: '$label'"

    handle_pr_labels "$pr" "$label"
}

handle_args()
{
    local pr="${1:-}"
    [ -z "$pr" ] && die "need PR number"

    handle_pr "$pr"
}

main()
{
    setup

    handle_args "$@"
}

main "$@"
