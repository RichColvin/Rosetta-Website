#!/bin/bash
#######################################################################
#                                                                     #
#   Rosetta website: publish from GitHub                              #
#                                                                     #
#######################################################################
#
# File:
#   rosetta_publish.sh
#
# Purpose:
#   Keeps rosetta.colvintools.com (GoDaddy, cPanel) in step with
#   GitHub. Run by a cPanel cron job every 15 minutes. For each repo it
#   keeps a copy in ~/rosetta_publish/repos/ (outside public_html, so
#   it's never served), fetches its branch, and when that has changed
#   copies what the website serves into the site's folder:
#
#     Rosetta (main)              Rosetta_User_Manual/   -> same name
#                                 Rosetta_Gcode_Library/ -> same name
#     RosettaSupportManual (main) Rosetta_Support_Manual/ -> same name
#     Rosetta-Website (main)      every file in the repo, except
#                                 .gitignore, README and publish/,
#                                 -> the site's own folder
#
#   A manual folder on the site is made an exact copy of the repo's
#   (a page removed in GitHub is removed from the site). The site's own
#   folder is only ever added to: nothing in it is removed, so the
#   Forum, Support/ (the version-report scripts and their data - never
#   touch them), the redirect-only UserManual/ and Gcode/ folders and
#   the manual folders are left alone. Names in PROTECTED are never
#   written by the Rosetta-Website copy even if that repo has them.
#
#   Edit pages in GitHub, not in cPanel's File Manager: a hand edit in
#   a published folder is overwritten at the next change.
#
# Usage:
#   bash rosetta_publish.sh             publish what has changed
#   bash rosetta_publish.sh --force     publish everything again
#   bash rosetta_publish.sh --dry-run   say what would be copied, change
#                                       nothing on the site
#   --site DIR / --work DIR             another site folder / work
#                                       folder (for testing)
#
# Log:
#   ~/rosetta_publish/publish.log (the last 1000 lines are kept)
#
# Version
#   1.0 - 22 November 2026
#   1.1 - 22 November 2026 - the website's file list through a file, not
#         process substitution (copied 0 files on GoDaddy); errors logged
#
# Copyright (c) 2026 Colvin Tools and Brainwave Embedded.
#######################################################################

SITE="$HOME/public_html/Rosetta"
WORK="$HOME/rosetta_publish"
GITHUB="https://github.com/RichColvin"

# repo  branch  folder in the repo (copied to the same name on the site)
MANUALS="
Rosetta              main Rosetta_User_Manual
Rosetta              main Rosetta_Gcode_Library
RosettaSupportManual main Rosetta_Support_Manual
"
WEBSITE_REPO="Rosetta-Website"
WEBSITE_BRANCH="main"

# Never written by the Rosetta-Website copy.
PROTECTED="Support Forum UserManual Gcode Rosetta_User_Manual
Rosetta_Gcode_Library Rosetta_Support_Manual cgi-bin .well-known
.htaccess publish"

FORCE=0
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --force)   FORCE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --site)    SITE="$2"; shift ;;
        --work)    WORK="$2"; shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

REPOS="$WORK/repos"
STATE="$WORK/state"
LOG="$WORK/publish.log"
mkdir -p "$REPOS" "$STATE" || exit 1
# anything the script itself complains about goes in the log too (cron
# throws its output away)
exec 2>>"$LOG"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
    [ -t 1 ] && echo "$*"
}

finish() {
    rm -rf "$WORK/lock"
    # keep the log short
    if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 1000 ]; then
        tail -n 1000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
}

# Only one copy at a time (a slow run must not overlap the next one).
if ! mkdir "$WORK/lock" 2>/dev/null; then
    # a lock older than an hour is left from a run that was killed
    if [ -n "$(find "$WORK/lock" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
        rm -rf "$WORK/lock"; mkdir "$WORK/lock" || exit 1
        log "Removed a lock left by an earlier run."
    else
        exit 0
    fi
fi
trap finish EXIT

GIT="$(command -v git || echo /usr/local/cpanel/3rdparty/bin/git)"
if [ ! -x "$GIT" ]; then
    log "ERROR: git not found."; exit 1
fi
if [ ! -d "$SITE" ]; then
    log "ERROR: the site folder $SITE isn't there - nothing published."; exit 1
fi
HAVE_RSYNC=0
command -v rsync >/dev/null 2>&1 && HAVE_RSYNC=1

# fetch REPO BRANCH -> prints the commit, or nothing on failure
fetch() {
    local repo="$1" branch="$2" dir="$REPOS/$1"
    if [ ! -d "$dir/.git" ]; then
        rm -rf "$dir"
        "$GIT" clone -q --depth 1 --branch "$branch" --single-branch \
            "$GITHUB/$repo.git" "$dir" >> "$LOG" 2>&1 || return 1
    else
        "$GIT" -C "$dir" fetch -q --depth 1 origin "$branch" >> "$LOG" 2>&1 || return 1
        "$GIT" -C "$dir" reset -q --hard FETCH_HEAD >> "$LOG" 2>&1 || return 1
        "$GIT" -C "$dir" clean -qfdx >> "$LOG" 2>&1
    fi
    "$GIT" -C "$dir" rev-parse HEAD
}

# changed KEY COMMIT -> true if not yet published (or --force)
changed() {
    [ "$FORCE" = 1 ] && return 0
    [ "$(cat "$STATE/$1" 2>/dev/null)" != "$2" ]
}

mark() {
    [ "$DRY_RUN" = 1 ] || echo "$2" > "$STATE/$1"
}

# mirror SOURCE_DIR TARGET_DIR: the target becomes an exact copy
mirror() {
    local src="$1" dst="$2"
    if [ "$DRY_RUN" = 1 ]; then
        log "  would make $dst an exact copy of $src ($(find "$src" -type f | wc -l | tr -d ' ') files)"
        return 0
    fi
    if [ "$HAVE_RSYNC" = 1 ]; then
        mkdir -p "$dst" && rsync -a --delete --exclude '.DS_Store' "$src/" "$dst/" >> "$LOG" 2>&1
    else
        # copy beside it, then swap the folders over
        rm -rf "$dst.new" "$dst.old"
        cp -R "$src" "$dst.new" || return 1
        [ -d "$dst" ] && mv "$dst" "$dst.old"
        mv "$dst.new" "$dst" && rm -rf "$dst.old"
    fi
}

is_protected() {
    local top="${1%%/*}" p
    for p in $PROTECTED; do
        [ "$top" = "$p" ] && return 0
    done
    return 1
}

FAILED=0

# The manuals
echo "$MANUALS" | while read -r repo branch folder; do
    [ -z "$repo" ] && continue
    commit="$(fetch "$repo" "$branch")"
    if [ -z "$commit" ]; then
        log "ERROR: couldn't fetch $repo ($branch) - $folder not published."
        echo fail >> "$WORK/lock/failed"; continue
    fi
    key="$folder"
    changed "$key" "$commit" || continue
    src="$REPOS/$repo/$folder"
    # never replace a working manual with an empty or broken one
    if [ ! -f "$src/index.html" ]; then
        log "ERROR: $repo ($branch) has no $folder/index.html - not published."
        echo fail >> "$WORK/lock/failed"; continue
    fi
    if mirror "$src" "$SITE/$folder"; then
        mark "$key" "$commit"
        [ "$DRY_RUN" = 1 ] || log "Published $folder from $repo $branch ${commit:0:7}."
    else
        log "ERROR: copying $folder failed."
        echo fail >> "$WORK/lock/failed"
    fi
done

# The website's own pages
commit="$(fetch "$WEBSITE_REPO" "$WEBSITE_BRANCH")"
if [ -z "$commit" ]; then
    log "ERROR: couldn't fetch $WEBSITE_REPO ($WEBSITE_BRANCH) - its pages not published."
    echo fail >> "$WORK/lock/failed"
elif changed website "$commit"; then
    src="$REPOS/$WEBSITE_REPO"
    count=0; skipped=""
    # (a file, not "< <(...)": process substitution can fail silently
    # in GoDaddy's locked-down cron environment)
    "$GIT" -C "$src" ls-files -z > "$WORK/lock/files" || {
        log "ERROR: couldn't list $WEBSITE_REPO's files."; echo fail >> "$WORK/lock/failed"; }
    while IFS= read -r -d '' f; do
        case "$f" in
            .gitignore|README*|publish/*) continue ;;
        esac
        if is_protected "$f"; then
            skipped="$skipped ${f%%/*}"; continue
        fi
        count=$((count + 1))
        [ "$DRY_RUN" = 1 ] && continue
        mkdir -p "$SITE/$(dirname "$f")" && cp -p "$src/$f" "$SITE/$f" || {
            log "ERROR: couldn't copy $f."; echo fail >> "$WORK/lock/failed"; }
    done < "$WORK/lock/files"
    [ -n "$skipped" ] && log "  left alone (protected):$(echo $skipped | tr ' ' '\n' | sort -u | tr '\n' ' ')"
    if [ "$DRY_RUN" = 1 ]; then
        log "  would copy $count files from $WEBSITE_REPO into $SITE (adding/replacing only)"
    else
        mark website "$commit"
        log "Published $count website files from $WEBSITE_REPO $WEBSITE_BRANCH ${commit:0:7}."
    fi
fi

[ -f "$WORK/lock/failed" ] && { rm -f "$WORK/lock/failed"; exit 1; }
exit 0
