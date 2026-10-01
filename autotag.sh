#!/usr/bin/env bash
 
# =============================================================================
# autotag.sh
#
# Requires:
#   Bash 3.2+
#   git 2.4+ (push --atomic)
#   date
#
# No external dependencies.
# =============================================================================
 
# Never let the shell expand '*', '?', '[' in unquoted variables
# (regexes from the configuration contain them).
set -f
 
 
# =============================================================================
# CONFIGURATION  (the only place with rule-specific information)
# =============================================================================
 
# Default rule alias. Empty = always ask.
DEFAULT_RULE="debug"
 
# Remote used for push.
REMOTE="origin"
 
# Separator between prefix and version. Part of the expanded prefix.
PREFIX_SEP="-"
 
 
# -----------------------------------------------------------------------------
# RULES
#
#   ALIASES | RULE | PREFIX | VARIANTS | DEFAULT_VARIANT
#
#   ALIASES          comma-separated aliases (the only thing -r accepts)
#   RULE             rule type; must have TEMPLATES and a handler function
#                    next_tag_<RULE> (see "TAG GENERATION")
#   PREFIX           [A-Za-z0-9_]*, may be empty
#   VARIANTS         space-separated variants, empty = no variants
#   DEFAULT_VARIANT  empty = always ask
# -----------------------------------------------------------------------------
 
RULES='
gp,getpulse | semvertag | gp    | major minor patch build rc | build
lotus,lm    | semvertag | lm    | major minor patch build rc | build
lqmini,lq   | semvertag | lq    | major minor patch build rc | build
debug       | bleeding  | debug |                            |
'
 
 
# -----------------------------------------------------------------------------
# TEMPLATES
#
#   RULE | KIND | FORMAT | REGEX
#
#   FORMAT  how a new tag is rendered. Placeholders:
#             {PREFIX}  prefix + PREFIX_SEP, or nothing if the prefix is empty
#             {MAJOR} {MINOR} {PATCH} {BUILD} {RC} {YEAR} {WEEK}
#   REGEX   ERE that recognises existing tags (REGEX is the last field, so it
#           may contain '|'). Placeholder:
#             {PREFIX?}  optional prefix group "(prefix-)?", or nothing
#           The regex MUST end with the numeric capture groups below; groups
#           are read from the END of the match, so the optional prefix group
#           never shifts the numbering:
#             semvertag/release : major minor patch build
#             semvertag/rc      : major minor patch rc
#             bleeding/release  : year week build
# -----------------------------------------------------------------------------
 
TEMPLATES='
semvertag | release | {PREFIX}{MAJOR}.{MINOR}.{PATCH}-{BUILD} | ^{PREFIX?}([0-9]+)\.([0-9]+)\.([0-9]+)-([0-9]+)$
semvertag | rc      | {PREFIX}{MAJOR}.{MINOR}.{PATCH}-rc{RC}  | ^{PREFIX?}([0-9]+)\.([0-9]+)\.([0-9]+)-rc([0-9]+)$
bleeding  | release | {PREFIX}{YEAR}.{WEEK}.{BUILD}           | ^{PREFIX?}([0-9]{2})\.([0-9]{2})\.([0-9]+)$
'
 
 
# =============================================================================
# GENERAL HELPERS
# =============================================================================
 
SCRIPT_NAME="$(basename "$0")"
 
error() {
    echo "Error: $*" >&2
}
 
warn() {
    echo "Warning: $*" >&2
}
 
die() {
    error "$*"
    exit 1
}
 
usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME [OPTIONS]
 
Options:
  -p, --path PATH       Git repository path.
  -r, --rule ALIAS      Rule alias (see RULES in the script).
  -h, --help            Show this help.
 
Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME --rule debug
  $SCRIPT_NAME -r gp
  $SCRIPT_NAME -p path/to/repo -r getpulse
EOF
}
 
# ask_yes_no QUESTION [y|n]   (second argument = default answer, default "n")
ask_yes_no() {
    local question="$1" default="${2:-n}" hint answer
 
    if [ "$default" = "y" ]; then
        hint="[Y/n]"
    else
        hint="[y/N]"
    fi
 
    while true; do
        printf "%s %s " "$question" "$hint"
 
        read -r answer || { echo; return 1; }
 
        case "$answer" in
            y|Y|yes|YES|Yes) return 0 ;;
            n|N|no|NO|No)    return 1 ;;
            "")
                if [ "$default" = "y" ]; then
                    return 0
                fi
                return 1
                ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
}
 
# Bash 3.2-compatible whitespace trimming.
trim() {
    local value="$1"
 
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
 
    printf '%s\n' "$value"
}
 
 
# =============================================================================
# CONFIGURATION ACCESS
# =============================================================================
 
# load_rule ALIAS
#
# Sets globals: RULE PREFIX VARIANTS DEFAULT_VARIANT
# Returns 1 if the alias is unknown.
load_rule() {
    local requested="$1" aliases rule prefix variants default
 
    while IFS='|' read -r aliases rule prefix variants default; do
 
        aliases="$(trim "$aliases")"
 
        [ -z "$aliases" ] && continue
 
        case "$aliases" in
            \#*) continue ;;
        esac
 
        aliases="${aliases// /}"
 
        case ",${aliases}," in
            *",${requested},"*)
                RULE="$(trim "$rule")"
                PREFIX="$(trim "$prefix")"
                VARIANTS="$(trim "$variants")"
                DEFAULT_VARIANT="$(trim "$default")"
                return 0
                ;;
        esac
 
    done <<EOF
$RULES
EOF
 
    return 1
}
 
rule_exists() {
    load_rule "$1"
}
 
# template_field RULE KIND regex|format
template_field() {
    local want_rule="$1" want_kind="$2" what="$3"
    local rule kind format regex
 
    while IFS='|' read -r rule kind format regex; do
 
        rule="$(trim "$rule")"
 
        [ -z "$rule" ] && continue
 
        case "$rule" in
            \#*) continue ;;
        esac
 
        kind="$(trim "$kind")"
 
        if [ "$rule" = "$want_rule" ] && [ "$kind" = "$want_kind" ]; then
            case "$what" in
                regex)  trim "$regex" ;;
                format) trim "$format" ;;
                *)      return 1 ;;
            esac
            return 0
        fi
 
    done <<EOF
$TEMPLATES
EOF
 
    return 1
}
 
# expand_regex RULE KIND PREFIX  -> final regex on stdout
expand_regex() {
    local regex optional=""
 
    regex="$(template_field "$1" "$2" regex)" || return 1
 
    if [ -n "$3" ]; then
        optional="(${3}${PREFIX_SEP})?"
    fi
 
    printf '%s\n' "${regex//\{PREFIX\?\}/$optional}"
}
 
# render_format FORMAT KEY VALUE [KEY VALUE ...]
render_format() {
    local out="$1"
    shift
 
    while [ $# -ge 2 ]; do
        out="${out//\{$1\}/$2}"
        shift 2
    done
 
    printf '%s\n' "$out"
}
 
# prefix_with_sep PREFIX -> "prefix-" or "" (for {PREFIX} in formats)
prefix_with_sep() {
    if [ -n "$1" ]; then
        printf '%s%s\n' "$1" "$PREFIX_SEP"
    fi
}
 
# Check that the loaded rule is consistent with the configuration.
validate_loaded_rule() {
    local handler
 
    case "$RULE" in
        ""|*[!A-Za-z0-9_]*)
            die "rule '$RULE_ALIAS': invalid rule type '$RULE'"
            ;;
    esac
 
    case "$PREFIX" in
        *[!A-Za-z0-9_]*)
            die "rule '$RULE_ALIAS': prefix '$PREFIX' may contain only [A-Za-z0-9_]"
            ;;
    esac
 
    handler="next_tag_${RULE}"
 
    if [ "$(type -t "$handler")" != "function" ]; then
        die "rule '$RULE_ALIAS': no handler '$handler' for rule type '$RULE'"
    fi
 
    if ! template_field "$RULE" release regex >/dev/null; then
        die "rule '$RULE': no 'release' template in TEMPLATES"
    fi
 
    if [ -n "$DEFAULT_VARIANT" ] && [ -n "$VARIANTS" ]; then
        is_valid_variant "$VARIANTS" "$DEFAULT_VARIANT" ||
            die "rule '$RULE_ALIAS': default variant '$DEFAULT_VARIANT' is not in VARIANTS"
    fi
}
 
print_available_rules() {
    local aliases rule prefix variants default
 
    echo "Available rules:"
 
    while IFS='|' read -r aliases rule prefix variants default; do
 
        aliases="$(trim "$aliases")"
 
        [ -z "$aliases" ] && continue
 
        case "$aliases" in
            \#*) continue ;;
        esac
 
        rule="$(trim "$rule")"
        prefix="$(trim "$prefix")"
 
        printf "  %-18s -> %-12s prefix=%s\n" \
            "$aliases" "$rule" "${prefix:-<none>}"
 
    done <<EOF
$RULES
EOF
}
 
 
# =============================================================================
# RULE SELECTION  (prompts go to stderr: stdout is captured by $(...))
# =============================================================================
 
ask_rule() {
    local answer
 
    while true; do
 
        {
            echo
            print_available_rules
            echo
            printf "Enter rule alias: "
        } >&2
 
        read -r answer || return 1
 
        if rule_exists "$answer"; then
            echo "$answer"
            return 0
        fi
 
        echo "Invalid rule: $answer" >&2
 
    done
}
 
 
# =============================================================================
# VARIANT SELECTION
# =============================================================================
 
normalize_variant() {
    case "$1" in
        M|major) echo "major" ;;
        m|minor) echo "minor" ;;
        p|patch) echo "patch" ;;
        b|build) echo "build" ;;
        rc)      echo "rc" ;;
        *)       echo "$1" ;;
    esac
}
 
is_valid_variant() {
    local variants="$1" requested="$2" v
 
    for v in $variants; do
        if [ "$v" = "$requested" ]; then
            return 0
        fi
    done
 
    return 1
}
 
ask_variant() {
    local variants="$1" answer
 
    while true; do
 
        {
            echo
            echo "Available variants: $variants"
            printf "Enter increment variant: "
        } >&2
 
        read -r answer || return 1
 
        answer="$(normalize_variant "$answer")"
 
        if is_valid_variant "$variants" "$answer"; then
            echo "$answer"
            return 0
        fi
 
        echo "Invalid variant: $answer" >&2
 
    done
}
 
 
# =============================================================================
# GIT HELPERS
# =============================================================================
 
git_cmd() {
    git -C "$REPO_PATH" "$@"
}
 
is_git_repository() {
    [ "$(git_cmd rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ]
}
 
get_current_branch() {
    git_cmd symbolic-ref --quiet --short HEAD
}
 
get_head_commit() {
    git_cmd rev-parse HEAD
}
 
 
# =============================================================================
# TAG SEARCH
# =============================================================================
 
# find_latest_semver REGEX
#
# Sets: LATEST_TAG LATEST_MAJOR LATEST_MINOR LATEST_PATCH LATEST_BUILD
# (all empty if nothing found). Captures are read from the END of
# BASH_REMATCH, so an optional prefix group does not matter.
find_latest_semver() {
    local regex="$1" tag n best="" key ma mi pa bu
 
    LATEST_TAG=""
    LATEST_MAJOR=""
    LATEST_MINOR=""
    LATEST_PATCH=""
    LATEST_BUILD=""
 
    while IFS= read -r tag; do
 
        [[ "$tag" =~ $regex ]] || continue
 
        n=${#BASH_REMATCH[@]}
 
        ma="${BASH_REMATCH[$((n - 4))]}"
        mi="${BASH_REMATCH[$((n - 3))]}"
        pa="${BASH_REMATCH[$((n - 2))]}"
        bu="${BASH_REMATCH[$((n - 1))]}"
 
        # 10# avoids octal interpretation of "08"; fixed width makes the
        # string comparison equal to the numeric one.
        printf -v key '%010d%010d%010d%010d' \
            "$((10#$ma))" "$((10#$mi))" "$((10#$pa))" "$((10#$bu))"
 
        if [ -z "$best" ] || [[ "$key" > "$best" ]]; then
            best="$key"
            LATEST_TAG="$tag"
            LATEST_MAJOR="$((10#$ma))"
            LATEST_MINOR="$((10#$mi))"
            LATEST_PATCH="$((10#$pa))"
            LATEST_BUILD="$((10#$bu))"
        fi
 
    done < <(git_cmd tag --list)
}
 
# find_latest_rc REGEX MAJOR MINOR PATCH
#
# Sets LATEST_RC: largest RC number for exactly this MAJOR.MINOR.PATCH.
find_latest_rc() {
    local regex="$1" want_ma="$2" want_mi="$3" want_pa="$4"
    local tag n rc
 
    LATEST_RC=""
 
    while IFS= read -r tag; do
 
        [[ "$tag" =~ $regex ]] || continue
 
        n=${#BASH_REMATCH[@]}
 
        [ "$((10#${BASH_REMATCH[$((n - 4))]}))" -eq "$want_ma" ] || continue
        [ "$((10#${BASH_REMATCH[$((n - 3))]}))" -eq "$want_mi" ] || continue
        [ "$((10#${BASH_REMATCH[$((n - 2))]}))" -eq "$want_pa" ] || continue
 
        rc="$((10#${BASH_REMATCH[$((n - 1))]}))"
 
        if [ -z "$LATEST_RC" ] || [ "$rc" -gt "$LATEST_RC" ]; then
            LATEST_RC="$rc"
        fi
 
    done < <(git_cmd tag --list)
}
 
 
# =============================================================================
# TAG GENERATION
#
# One handler per rule type: next_tag_<RULE> RULE PREFIX VARIANT
# Every handler sets NEW_TAG (and optionally PREVIOUS_TAG) and returns 0.
# Formats and regexes come from TEMPLATES, not from here.
# =============================================================================
 
# semvertag:
#   7.1.3-12 -> major -> 8.0.0-1
#   7.1.3-12 -> minor -> 7.2.0-1
#   7.1.3-12 -> patch -> 7.1.4-1
#   7.1.3-12 -> build -> 7.1.3-13
#   7.1.3-12 -> rc    -> 7.1.3-rc1, 7.1.3-rc2, ...
# No previous release: counting starts from 0.0.0 (build 0).
next_tag_semvertag() {
    local rule="$1" prefix="$2" variant="$3"
    local re_release re_rc fmt pfx major minor patch build rc
 
    re_release="$(expand_regex "$rule" release "$prefix")" || return 1
 
    find_latest_semver "$re_release"
 
    PREVIOUS_TAG="$LATEST_TAG"
 
    if [ -n "$LATEST_TAG" ]; then
        major="$LATEST_MAJOR"
        minor="$LATEST_MINOR"
        patch="$LATEST_PATCH"
        build="$LATEST_BUILD"
    else
        major=0
        minor=0
        patch=0
        build=0
    fi
 
    pfx="$(prefix_with_sep "$prefix")"
 
    case "$variant" in
        major) major=$((major + 1)); minor=0; patch=0; build=1 ;;
        minor) minor=$((minor + 1)); patch=0; build=1 ;;
        patch) patch=$((patch + 1)); build=1 ;;
        build) build=$((build + 1)) ;;
        rc)
            re_rc="$(expand_regex "$rule" rc "$prefix")" || return 1
            fmt="$(template_field "$rule" rc format)" || return 1
 
            find_latest_rc "$re_rc" "$major" "$minor" "$patch"
 
            rc=$(( ${LATEST_RC:-0} + 1 ))
 
            NEW_TAG="$(render_format "$fmt" \
                PREFIX "$pfx" MAJOR "$major" MINOR "$minor" \
                PATCH "$patch" RC "$rc")"
 
            return 0
            ;;
        *)
            error "unsupported variant for $rule: '$variant'"
            return 1
            ;;
    esac
 
    fmt="$(template_field "$rule" release format)" || return 1
 
    NEW_TAG="$(render_format "$fmt" \
        PREFIX "$pfx" MAJOR "$major" MINOR "$minor" \
        PATCH "$patch" BUILD "$build")"
}
 
# bleeding:  <prefix->YY.WW.N   (YY = ISO year, WW = ISO week, N from 0)
next_tag_bleeding() {
    local rule="$1" prefix="$2"
    local regex fmt pfx year week tag n build latest_build=-1
 
    regex="$(expand_regex "$rule" release "$prefix")" || return 1
    fmt="$(template_field "$rule" release format)" || return 1
 
    year="$(date +%g)"
    week="$(date +%V)"
 
    PREVIOUS_TAG=""
 
    while IFS= read -r tag; do
 
        [[ "$tag" =~ $regex ]] || continue
 
        n=${#BASH_REMATCH[@]}
 
        [ "$((10#${BASH_REMATCH[$((n - 3))]}))" -eq "$((10#$year))" ] || continue
        [ "$((10#${BASH_REMATCH[$((n - 2))]}))" -eq "$((10#$week))" ] || continue
 
        build="$((10#${BASH_REMATCH[$((n - 1))]}))"
 
        if [ "$build" -gt "$latest_build" ]; then
            latest_build="$build"
            PREVIOUS_TAG="$tag"
        fi
 
    done < <(git_cmd tag --list)
 
    pfx="$(prefix_with_sep "$prefix")"
 
    NEW_TAG="$(render_format "$fmt" \
        PREFIX "$pfx" YEAR "$year" WEEK "$week" \
        BUILD "$((latest_build + 1))")"
}
 
 
# =============================================================================
# MAIN
# =============================================================================
 
# -----------------------------------------------------------------------------
# 1. Parse command line.
# -----------------------------------------------------------------------------
 
REPO_PATH="."
CLI_RULE=""
 
while [ $# -gt 0 ]; do
 
    case "$1" in
 
        -p|--path)
            [ $# -ge 2 ] || die "option $1 requires a path"
            REPO_PATH="$2"
            shift 2
            ;;
 
        -r|--rule)
            [ $# -ge 2 ] || die "option $1 requires a rule"
            CLI_RULE="$2"
            shift 2
            ;;
 
        -h|--help)
            usage
            exit 0
            ;;
 
        *)
            usage >&2
            die "unknown option: $1"
            ;;
 
    esac
 
done
 
 
# -----------------------------------------------------------------------------
# 2. Check Git repository.
# -----------------------------------------------------------------------------
 
if ! is_git_repository; then
    die "path is not a git work tree: $REPO_PATH"
fi
 
REPO_ROOT="$(git_cmd rev-parse --show-toplevel)" ||
    die "failed to determine git repository root"
 
REPO_PATH="$REPO_ROOT"
 
 
# -----------------------------------------------------------------------------
# 3. Fetch tags.
# -----------------------------------------------------------------------------
 
echo "Fetching tags from '$REMOTE'..."
 
git_cmd fetch --tags --force "$REMOTE" ||
    die "failed to fetch tags from '$REMOTE'"
 
 
# -----------------------------------------------------------------------------
# 4. Check active branch.
# -----------------------------------------------------------------------------
 
CURRENT_BRANCH="$(get_current_branch)" ||
    die "cannot determine active branch; detached HEAD is not supported"
 
 
# -----------------------------------------------------------------------------
# 5. Check HEAD commit.
# -----------------------------------------------------------------------------
 
HEAD_COMMIT="$(get_head_commit)" ||
    die "cannot determine HEAD commit"
 
echo "Repository: $REPO_PATH"
echo "Branch:     $CURRENT_BRANCH"
echo "Commit:     $HEAD_COMMIT"
 
if [ -n "$(git_cmd status --porcelain --untracked-files=no)" ]; then
    warn "working tree has uncommitted changes; the tag points to HEAD only"
fi
 
 
# -----------------------------------------------------------------------------
# 6. Check tags on current commit.
# -----------------------------------------------------------------------------
 
HEAD_TAGS="$(git_cmd tag --points-at "$HEAD_COMMIT")"
 
if [ -n "$HEAD_TAGS" ]; then
 
    echo
    echo "The current commit already has tag(s):"
    echo "$HEAD_TAGS"
    echo
 
    if ! ask_yes_no "Continue and create another tag on this commit?" n; then
        echo "Nothing changed."
        exit 0
    fi
 
fi
 
 
# -----------------------------------------------------------------------------
# 7. Validate configuration.
# -----------------------------------------------------------------------------
 
if [ -z "$(trim "$RULES")" ]; then
    die "no rules are configured"
fi
 
 
# -----------------------------------------------------------------------------
# 8. Select rule.
# -----------------------------------------------------------------------------
 
RULE_ALIAS="$CLI_RULE"
 
if [ -z "$RULE_ALIAS" ]; then
 
    if [ -n "$DEFAULT_RULE" ]; then
 
        echo
        echo "Default rule is: $DEFAULT_RULE"
 
        if ask_yes_no "Continue with this rule?" y; then
            RULE_ALIAS="$DEFAULT_RULE"
        fi
 
    fi
 
    if [ -z "$RULE_ALIAS" ]; then
        RULE_ALIAS="$(ask_rule)" || die "no rule selected"
    fi
 
fi
 
 
# -----------------------------------------------------------------------------
# 9. Read rule configuration.
# -----------------------------------------------------------------------------
 
if ! load_rule "$RULE_ALIAS"; then
 
    echo
    print_available_rules
    echo
 
    die "invalid rule alias: $RULE_ALIAS"
fi
 
validate_loaded_rule
 
echo
echo "Rule:       $RULE"
echo "Alias:      $RULE_ALIAS"
echo "Prefix:     ${PREFIX:-<none>}"
 
 
# -----------------------------------------------------------------------------
# 10. Select variant.
# -----------------------------------------------------------------------------
 
VARIANT=""
 
if [ -n "$VARIANTS" ]; then
 
    if [ -n "$DEFAULT_VARIANT" ]; then
 
        echo
        echo "Default increment variant is: $DEFAULT_VARIANT"
 
        if ask_yes_no "Continue with variant '$DEFAULT_VARIANT'?" y; then
            VARIANT="$DEFAULT_VARIANT"
        fi
 
    fi
 
    if [ -z "$VARIANT" ]; then
        VARIANT="$(ask_variant "$VARIANTS")" || die "no variant selected"
    fi
 
    VARIANT="$(normalize_variant "$VARIANT")"
 
    is_valid_variant "$VARIANTS" "$VARIANT" ||
        die "invalid variant '$VARIANT' for rule '$RULE_ALIAS'"
 
fi
 
 
# -----------------------------------------------------------------------------
# 11. Calculate next tag.
# -----------------------------------------------------------------------------
 
echo
echo "Calculating next tag..."
 
NEW_TAG=""
PREVIOUS_TAG=""
 
"next_tag_${RULE}" "$RULE" "$PREFIX" "$VARIANT" ||
    die "failed to calculate next tag"
 
[ -n "$NEW_TAG" ] || die "failed to calculate next tag"
 
echo "Previous tag: ${PREVIOUS_TAG:-none}"
echo "New tag:      $NEW_TAG"
 
 
# -----------------------------------------------------------------------------
# 12. Make sure generated tag doesn't already exist.
# -----------------------------------------------------------------------------
 
if git_cmd rev-parse --verify --quiet "refs/tags/$NEW_TAG" >/dev/null; then
    die "calculated tag already exists: $NEW_TAG"
fi
 
 
# -----------------------------------------------------------------------------
# 13. Confirm creation.
# -----------------------------------------------------------------------------
 
echo
 
if ! ask_yes_no \
    "Create tag and push branch '$CURRENT_BRANCH' + tag to '$REMOTE'?" n; then
    echo "Nothing changed."
    exit 0
fi
 
 
# -----------------------------------------------------------------------------
# 14. Create local tag.
# -----------------------------------------------------------------------------
 
git_cmd tag "$NEW_TAG" "$HEAD_COMMIT" ||
    die "failed to create tag '$NEW_TAG'"
 
echo "Tag created locally: $NEW_TAG"
 
 
# -----------------------------------------------------------------------------
# 15. Push branch and tag atomically.
# -----------------------------------------------------------------------------
 
echo
echo "Pushing branch '$CURRENT_BRANCH' and tag '$NEW_TAG'..."
 
git_cmd push --atomic "$REMOTE" \
    "HEAD:refs/heads/${CURRENT_BRANCH}" \
    "refs/tags/${NEW_TAG}"
 
PUSH_EXIT_CODE=$?
 
if [ "$PUSH_EXIT_CODE" -ne 0 ]; then
 
    echo >&2
    error "push failed; the tag exists only locally: $NEW_TAG"
    echo "To remove it:  git -C \"$REPO_PATH\" tag -d \"$NEW_TAG\"" >&2
 
    exit "$PUSH_EXIT_CODE"
fi
 
echo
echo "Successfully pushed:"
echo "  branch: $CURRENT_BRANCH"
echo "  tag:    $NEW_TAG"
 
exit 0