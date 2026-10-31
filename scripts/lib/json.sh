# shellcheck shell=bash

# shortcut: invalid UTF-8 bytes pass through unchanged (jq emitted U+FFFD), so a strict JSON parser may reject them; pipe through `iconv -c` if a host does.
# json_str: stdin -> JSON string literal, quotes included. Exact for any input; non-ASCII passes through as UTF-8.
json_str() {
  printf '"'
  # the trailing x keeps the last line's newline (or its absence) observable; awk drops it again
  { cat; printf x; } | LC_ALL=C awk '
    function esc(s, k,  n, a, i) {
      if (s ~ /^[ !#-[^-~]*$/) { printf "%s", s; return }
      while (k <= NS && index(s, SEP[k]) == 0) k++
      if (k > NS) { printf "%s", s; return }
      n = split(s, a, SEP[k])
      for (i = 1; i <= n; i++) { if (i > 1) printf "%s", REP[k]; esc(a[i], k + 1) }
    }
    BEGIN {
      SEP[1] = "\\"; REP[1] = "\\\\"
      SEP[2] = "\""; REP[2] = "\\\""
      NS = 2
      for (c = 1; c < 32; c++) {
        if (c == 10) continue
        NS++; SEP[NS] = sprintf("%c", c)
        REP[NS] = c == 8 ? "\\b" : c == 9 ? "\\t" : c == 12 ? "\\f" : c == 13 ? "\\r" : sprintf("\\u%04x", c)
      }
    }
    NR > 1 { esc(prev, 1); printf "\\n" }
    { prev = $0 }
    END { esc(substr(prev, 1, length(prev) - 1), 1) }
  '
  printf '"'
}

# json_raw KEY: stdin JSON on one line -> raw (still escaped) content of the string KEY, or of the first string of an
# array KEY; empty when absent or not a string. An escaped decoy (\"KEY\") inside another value never matches.
# shortcut: matches at any depth and the last occurrence wins; hosts send these keys at top level only.
json_raw() {
  LC_ALL=C sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*\[\{0,1\}[[:space:]]*"/"/p' |
    LC_ALL=C awk 'match($0, /^"([^"\\]|\\.)*"/) { printf "%s", substr($0, 2, RLENGTH - 2) }'
}
