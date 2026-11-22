#!/bin/bash
#######################################################################
#                                                                     #
#   Rosetta and Sharpening Handbook websites: publish from GitHub    #
#                                                                     #
#######################################################################
#
# File:
#   rosetta_publish.sh
#
# Purpose:
#   Keeps rosetta.colvintools.com and sharpeninghandbook.info (GoDaddy,
#   cPanel, one account) in step with GitHub. Run by a cPanel cron job
#   every 15 minutes. For each repo it keeps a copy in
#   ~/rosetta_publish/repos/ (outside public_html, so it's never
#   served), fetches its branch, and when that has changed copies what
#   the website serves:
#
#     Rosetta (main)              Rosetta_User_Manual/   -> same name
#                                 Rosetta_Gcode_Library/ -> same name
#                                 in public_html/Rosetta/
#     RosettaSupportManual (main) Rosetta_Support_Manual/ -> same name
#                                 in public_html/Rosetta/
#     Rosetta-Website (main)      every file in the repo, except those
#                                 left out (WHOLE_SITES) -> public_html/
#                                 Rosetta/
#     Sharpening-Handbook (main)  the same -> public_html/
#                                 SharpeningHandbook/
#
#   A manual folder on the site is made an exact copy of the repo's
#   (a page removed in GitHub is removed from the site). A whole site's
#   folder is only ever added to, and only files whose contents changed
#   are copied: nothing in it is removed, so on the Rosetta site the
#   Forum, Support/ (the version-report scripts and their data - never
#   touch them), the redirect-only UserManual/ and Gcode/ folders and
#   the manual folders are left alone. A site's protected names are
#   never written even if its repo has them.
#
#   Edit pages in GitHub, not in cPanel's File Manager: a hand edit in
#   a published folder is overwritten at the next change.
#
# Usage:
#   bash rosetta_publish.sh             publish what has changed
#   bash rosetta_publish.sh --force     publish everything again
#   bash rosetta_publish.sh --dry-run   say what would be copied, change
#                                       nothing on the site
#   --public DIR / --work DIR           another public_html / work
#                                       folder (for testing)
#
# Log:
#   ~/rosetta_publish/publish.log (the last 1000 lines are kept)
#
# Version
#   1.0 - 22 November 2026
#   1.1 - 22 November 2026 - the website's file list through a file, not
#         process substitution (copied 0 files on GoDaddy); errors logged
#   1.2 - 22 November 2026 - the Sharpening Handbook too (WHOLE_SITES);
#         a whole site copies only the files that changed
#
# Copyright (c) 2026 Colvin Tools and Brainwave Embedded.
#######################################################################

PUBLIC="$HOME/public_html"
WORK="$HOME/rosetta_publish"
GITHUB="https://github.com/RichColvin"

# repo  branch  folder in the repo (copied to the same name in
# public_html/Rosetta/)
MANUALS="
Rosetta              main Rosetta_User_Manual
Rosetta              main Rosetta_Gcode_Library
RosettaSupportManual main Rosetta_Support_Manual
"

# Whole sites, one per line:
#   repo | branch | folder in public_html | left out (patterns, ";"
#   between) | protected (top-level names never written, spaces between)
WHOLE_SITES="
Rosetta-Website|main|Rosetta|.gitignore;README*;LICENSE;publish/*;*.DS_Store|Support Forum UserManual Gcode Rosetta_User_Manual Rosetta_Gcode_Library Rosetta_Support_Manual cgi-bin .well-known .htaccess publish
Sharpening-Handbook|main|SharpeningHandbook|.gitignore;README*;LICENSE;book-build/*;_Web Site Documents/*;*.DS_Store|cgi-bin .well-known .htaccess
"

FORCE=0
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --force)   FORCE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --public)  PUBLIC="$2"; shift ;;
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
SITE="$PUBLIC/Rosetta"
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

# is_protected FILE "NAMES"
is_protected() {
    local top="${1%%/*}" p
    for p in $2; do
        [ "$top" = "$p" ] && return 0
    done
    return 1
}

# is_left_out FILE "PATTERN;PATTERN..."
is_left_out() {
    local f="$1" p rest="$2;"
    while [ -n "$rest" ]; do
        p="${rest%%;*}"; rest="${rest#*;}"
        [ -n "$p" ] || continue
        # shellcheck disable=SC2053
        [[ "$f" == $p ]] && return 0
        [[ "${f##*/}" == $p ]] && return 0
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

# Whole sites (the Rosetta site's own pages, the Sharpening Handbook)
echo "$WHOLE_SITES" > "$WORK/lock/sites"
while IFS='|' read -r repo branch folder leave_out protected; do
    [ -z "$repo" ] && continue
    target="$PUBLIC/$folder"
    if [ ! -d "$target" ]; then
        log "ERROR: $target isn't there - $repo not published."
        echo fail >> "$WORK/lock/failed"; continue
    fi
    commit="$(fetch "$repo" "$branch")"
    if [ -z "$commit" ]; then
        log "ERROR: couldn't fetch $repo ($branch) - not published."
        echo fail >> "$WORK/lock/failed"; continue
    fi
    key="site-$repo"
    changed "$key" "$commit" || continue
    src="$REPOS/$repo"
    copied=0; same=0; skipped=""
    # (a file, not "< <(...)": process substitution can fail silently
    # in GoDaddy's locked-down cron environment)
    if ! "$GIT" -C "$src" ls-files -z > "$WORK/lock/files"; then
        log "ERROR: couldn't list $repo's files."; echo fail >> "$WORK/lock/failed"; continue
    fi
    failed=0
    while IFS= read -r -d '' f; do
        is_left_out "$f" "$leave_out" && continue
        if is_protected "$f" "$protected"; then
            skipped="$skipped ${f%%/*}"; continue
        fi
        if cmp -s "$src/$f" "$target/$f"; then
            same=$((same + 1)); continue
        fi
        copied=$((copied + 1))
        [ "$DRY_RUN" = 1 ] && continue
        mkdir -p "$target/$(dirname "$f")" && cp -p "$src/$f" "$target/$f" || {
            log "ERROR: couldn't copy $f."; failed=1; }
    done < "$WORK/lock/files"
    [ -n "$skipped" ] && log "  $repo - left alone (protected):$(echo $skipped | tr ' ' '\n' | sort -u | tr '\n' ' ')"
    if [ "$DRY_RUN" = 1 ]; then
        log "  would copy $copied changed files from $repo into $target ($same already the same; adding/replacing only)"
    elif [ "$failed" = 1 ]; then
        echo fail >> "$WORK/lock/failed"
        log "ERROR: $repo only partly published ($copied files tried) - tried again next run."
    else
        mark "$key" "$commit"
        log "Published $repo $branch ${commit:0:7}: $copied changed files copied, $same already the same."
    fi
done < "$WORK/lock/sites"

[ -f "$WORK/lock/failed" ] && { rm -f "$WORK/lock/failed"; exit 1; }
exit 0
