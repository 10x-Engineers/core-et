#!/usr/bin/env bash
# Copyright (c) 2026 Ainekko
# SPDX-License-Identifier: Apache-2.0
#
# Flattens nested filelists into one list with every entry kept once.
#
# The project filelists nest: neigh_top_rtl.f, neigh_channel_rtl.f,
# minion_top_rtl.f, esr_rtl.f and txfma_rtl.f each include libs_rtl.f.
# VCS and Verilator accept a repeated -f, but xmvlog stops with
# *F,REARGF. This script follows every -f once, expands $RTLROOT and
# $REPOROOT, drops comments and blank lines, and prints each remaining
# entry once in first-seen order.
#
# Usage: flatten_flist.sh top1.f [top2.f ...] > flat.f

set -euo pipefail

declare -A seen_file=()
declare -A seen_line=()

expand() {
  local s=$1
  s=${s//\$\{RTLROOT\}/$RTLROOT}
  s=${s//\$RTLROOT/$RTLROOT}
  s=${s//\$\{REPOROOT\}/${REPOROOT:-}}
  s=${s//\$REPOROOT/${REPOROOT:-}}
  printf '%s' "$s"
}

walk() {
  local f
  f=$(expand "$1")
  if [[ ! -f $f ]]; then
    echo "flatten_flist.sh: cannot read $f" >&2
    exit 1
  fi
  [[ -n ${seen_file[$f]:-} ]] && return 0
  seen_file[$f]=1

  local line
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%//*}                              # strip // comments
    line=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"$line")
    [[ -z $line ]] && continue
    if [[ $line =~ ^-f[[:space:]]+(.+)$ ]]; then
      walk "${BASH_REMATCH[1]}"
    else
      line=$(expand "$line")
      [[ -n ${seen_line[$line]:-} ]] && continue
      seen_line[$line]=1
      printf '%s\n' "$line"
    fi
  done < "$f"
}

: "${RTLROOT:?RTLROOT must be set}"
for top in "$@"; do walk "$top"; done
