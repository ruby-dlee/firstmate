#!/usr/bin/env bash
# fm-toon-lib.sh - a strict, structurally aware TOON reader for payloads that
# gate an unattended merge.
#
# Why this exists: bin/fm-pr-merge.sh arms merges without a human watching, and
# it decided "is this PR a draft / is it merged" by pattern-matching the text of
# gh-axi output with `sed | head -1`. Every fault that shape produced failed in
# the same direction - it UNDER-REPORTED. A key matched at any depth, an
# unmatched quote was stripped into a valid-looking value, a case variant was
# accepted, and a value it could not understand fell back to a benign default.
# Each of those makes a PR read greener than it is. Leniency in a merge gate is
# not robustness; it is a silent yes.
#
# So this reader is positive, not permissive. It parses the WHOLE document
# structurally - tracking indentation, nesting, and array position - before it
# answers any lookup, and it refuses on anything it cannot account for. A key
# means what its POSITION says it means, not merely that its text matched
# somewhere. The four properties it enforces, in the order they matter:
#
#   1. Every line is positively classified. A line that matches none of the
#      known forms is a hard error naming the line number and the line. Nothing
#      is skipped, and nothing is absorbed into the previous record as a
#      continuation-by-default.
#   2. Declared counts are verified. A `key[N]` header whose block does not hold
#      exactly N records is an error naming BOTH numbers. Rows are never
#      truncated to the declared count, and undeclared trailing rows are never
#      ignored.
#   3. No coercion. Nothing is lowercased, quote-repaired, trimmed into validity,
#      or defaulted. A value that starts with a quote must be a well-formed
#      quoted string or it is an error - it is never stripped into a bare word.
#      All scalars go through scalar_ok/decode, and all booleans through the
#      closed whitelist in fm_toon_bool. There is exactly one decoder each.
#   4. Unknown is never permissive. A missing path, an unparseable document, and
#      an unrecognized boolean are all non-zero exits, so a caller that treats
#      non-zero as "refuse" can never read silence as consent.
#
# Grammar accepted (all of it observed in real gh-axi output; see
# tests/fixtures/toon/*.toon, captured 2026-08-03):
#
#   key: value                     scalar; value is VERBATIM after exactly one
#                                  space, never trimmed
#   key:                           object header; children sit at indent + 2
#   key: []                        empty array
#   key[N]{f1,f2}:                 tabular array; N rows at indent + 2, each row
#                                  holding exactly the declared fields
#   key[N]:                        list array; either N items one per line, or a
#                                  single line of N comma-separated items
#   - key: value                   expanded-array item; the dash-space marker is
#                                  what starts an item, so an item whose first
#                                  key is anything at all still counts as one
#
# Indentation is exactly two spaces per level and a child must sit at exactly
# parent + 2. That is the structural half of property 1: a key nested under an
# unrelated parent can no longer satisfy a lookup meant for the top level,
# because the lookup is by PATH (`pull_request.state`), not by text.
#
# Paths are dot-separated with zero-based array subscripts:
#   pull_request.state      checks[0].conclusion      help[1]
#
# API (document on stdin):
#   fm_toon_get <path>    print the decoded scalar at <path>
#   fm_toon_bool <path>   print true|false for a strict boolean at <path>
#   fm_toon_root_key      print the single top-level block key
#   fm_toon_validate      parse and validate the whole document, print nothing
#
# Exit codes - both non-zero cases mean REFUSE, and callers must treat them that
# way rather than distinguishing them to find a permissive path:
#   0  ok
#   2  document invalid, or value not a strict boolean (message on stderr)
#   3  no such path (message on stderr)
#
# Deliberately strict choices, each of which fails toward refusing a merge:
#   - A blank line is an error. Real gh-axi payloads contain none, so a blank
#     line means the stream is not what we think it is (a stray warning, an
#     interleaved stderr write) and guessing its meaning is exactly the class of
#     leniency this library exists to remove.
#   - A duplicate path is an error rather than first-match-wins.
#   - A value with leading whitespace after the colon is an error, so a value is
#     never trimmed into a match.
#   - A \u escape in a value being RETURNED is an error; it is accepted as
#     well-formed during validation but this reader does not decode it, and
#     guessing is worse than refusing. No current call site needs one.
#
# Why this is hand-written rather than shelling out to a decoder: there is no
# `toon` binary on this machine and `gh-axi` has no JSON output mode (`gh-axi pr
# view --help` lists only --comments, --reviews, and --full), so every consumer
# of gh-axi output has to read TOON itself. Verified 2026-08-03.
#
# Sourced by bin/fm-pr-merge.sh and the tests. No side effects on source.
# set -u / set -e safe. Written for POSIX awk (no gawk extensions, no regex
# interval expressions) so it behaves the same under macOS awk and Linux mawk.

# The awk reader. Single-quoted so the shell expands nothing; the program itself
# therefore contains no apostrophes.
# shellcheck disable=SC2016  # the awk program must reach awk verbatim: $0, $1
# and every awk variable in it are awk syntax, and shell expansion would corrupt
# the parser this whole library exists to make trustworthy.
FM_TOON_AWK='
function err(msg) {
  print "fm-toon: " msg
  aborted = 1
  exit 2
}

function is_escape_char(e) {
  return (length(e) == 1 && index("\"\\/bfnrt", e) > 0)
}

function is_hex4(h,   j) {
  if (length(h) != 4) return 0
  for (j = 1; j <= 4; j++)
    if (index("0123456789abcdefABCDEF", substr(h, j, 1)) == 0) return 0
  return 1
}

# A raw scalar is valid when it is either a well-formed quoted string or a
# non-empty unquoted literal. Nothing is repaired: an unmatched quote is
# rejected outright rather than stripped into a bare word.
function scalar_ok(v,   n, i, c, e) {
  if (v == "") return 0
  if (substr(v, 1, 1) != "\"") {
    if (substr(v, 1, 1) == "[") return 0
    if (substr(v, 1, 1) == " ") return 0
    return 1
  }
  n = length(v)
  if (n < 2) return 0
  if (substr(v, n, 1) != "\"") return 0
  i = 2
  while (i <= n - 1) {
    c = substr(v, i, 1)
    if (c == "\\") {
      if (i + 1 > n - 1) return 0
      e = substr(v, i + 1, 1)
      if (e == "u") {
        if (i + 5 > n - 1) return 0
        if (!is_hex4(substr(v, i + 2, 4))) return 0
        i += 6
        continue
      }
      if (!is_escape_char(e)) return 0
      i += 2
      continue
    }
    if (c == "\"") return 0
    i++
  }
  return 1
}

# The one scalar decoder. Only ever applied to the value actually being
# returned, so a malformed escape deep in an unread field still fails validation
# above without this having to guess at it.
function decode(v, where,   n, i, c, e, out) {
  if (substr(v, 1, 1) != "\"") return v
  n = length(v)
  out = ""
  i = 2
  while (i <= n - 1) {
    c = substr(v, i, 1)
    if (c == "\\") {
      e = substr(v, i + 1, 1)
      if (e == "u") {
        err("value at " where " contains a \\u escape this reader does not decode; refusing rather than guessing")
        return ""
      }
      if (e == "n") out = out "\n"
      else if (e == "t") out = out "\t"
      else if (e == "r") out = out "\r"
      else if (e == "b") out = out sprintf("%c", 8)
      else if (e == "f") out = out sprintf("%c", 12)
      else out = out e
      i += 2
      continue
    }
    out = out c
    i++
  }
  return out
}

# Quote-aware comma split. Returns the field count, or -1 when a quoted field is
# unterminated or a closing quote is not followed by a comma.
function split_row(s, arr,   n, i, j, c, cur, L) {
  L = length(s)
  n = 0
  i = 1
  if (L == 0) { arr[1] = ""; return 1 }
  while (1) {
    if (substr(s, i, 1) == "\"") {
      cur = "\""
      j = i + 1
      while (1) {
        if (j > L) return -1
        c = substr(s, j, 1)
        if (c == "\\") {
          if (j + 1 > L) return -1
          cur = cur c substr(s, j + 1, 1)
          j += 2
          continue
        }
        cur = cur c
        j++
        if (c == "\"") break
      }
      arr[++n] = cur
      if (j > L) break
      if (substr(s, j, 1) != ",") return -1
      i = j + 1
      if (i > L) { arr[++n] = ""; break }
    } else {
      c = index(substr(s, i), ",")
      if (c == 0) { arr[++n] = substr(s, i); break }
      arr[++n] = substr(s, i, c - 1)
      i = i + c
      if (i > L) { arr[++n] = ""; break }
    }
  }
  return n
}

function path_join(parent, key) {
  return (parent == "") ? key : parent "." key
}

# Remember top-level keys in document order so fm_toon_root_key can name the
# single root block. gh-axi labels a merge result with the OUTCOME as the block
# key (merge:, merged:, enqueued:), so reading that label is a real lookup, not
# a guess - but it is only meaningful when there is exactly one root block.
function note_root(parent, key) {
  if (parent != "" || (key in rootseen)) return
  rootseen[key] = 1
  rootorder[++nroot] = key
}

function declare_path(p) {
  if (p in declared) err("duplicate path " p " at line " lineno "; refusing rather than picking one")
  declared[p] = 1
}

function setval(p, raw) {
  declare_path(p)
  if (!scalar_ok(raw)) err("line " lineno ": malformed scalar at " p ": [" raw "]")
  val[p] = raw
}

function is_key(k) {
  return (k ~ /^[A-Za-z_][A-Za-z0-9_-]*$/)
}

# Is head of the form key[N] ? Sets HKEY and HCOUNT.
function parse_count_head(head,   ob, cb, k, c) {
  ob = index(head, "[")
  if (ob < 2) return 0
  cb = length(head)
  if (substr(head, cb, 1) != "]") return 0
  k = substr(head, 1, ob - 1)
  c = substr(head, ob + 1, cb - ob - 1)
  if (!is_key(k)) return 0
  if (c == "" || c ~ /[^0-9]/) return 0
  HKEY = k
  HCOUNT = c + 0
  return 1
}

# Is head of the form key[N]{f1,f2} ? Sets HKEY, HCOUNT, HFIELDS.
function parse_table_head(head,   ob, k, rest, bo, bc) {
  bo = index(head, "{")
  if (bo < 2) return 0
  bc = length(head)
  if (substr(head, bc, 1) != "}") return 0
  rest = substr(head, bo + 1, bc - bo - 1)
  if (!parse_count_head(substr(head, 1, bo - 1))) return 0
  HFIELDS = rest
  return 1
}

function push(kind, ind, p) {
  depth++
  ctx_kind[depth] = kind
  ctx_indent[depth] = ind
  ctx_path[depth] = p
  ctx_expect[depth] = 0
  ctx_seen[depth] = 0
  ctx_lmode[depth] = ""
  ctx_nfields[depth] = 0
}

function close_ctx(d,   cnt, parts, i, seen) {
  if (ctx_kind[d] == "tab") {
    if (ctx_seen[d] != ctx_expect[d])
      err(sprintf("array %s declares [%d] but its block holds %d rows", ctx_path[d], ctx_expect[d], ctx_seen[d]))
    return
  }
  if (ctx_kind[d] != "lst") return
  seen = ctx_seen[d]
  if (ctx_lmode[d] == "exp") {
    if (seen != ctx_expect[d])
      err(sprintf("array %s declares [%d] but its block holds %d items", ctx_path[d], ctx_expect[d], seen))
    return
  }
  if (seen == ctx_expect[d]) {
    for (i = 1; i <= seen; i++) {
      if (index(ctx_items[d SUBSEP i], ",") != 0)
        err(sprintf("array %s can be read as both a %d-line block and a comma-separated inline list; refusing ambiguous list grammar", ctx_path[d], seen))
      setval(ctx_path[d] "[" (i - 1) "]", ctx_items[d SUBSEP i])
    }
    return
  }
  # A single physical line may carry N comma-separated items (the inline list
  # form gh-axi emits for compact lists). That is the ONLY alternative reading,
  # and it must still produce exactly N items.
  if (seen == 1 && ctx_expect[d] != 1) {
    cnt = split_row(ctx_items[d SUBSEP 1], parts)
    if (cnt != ctx_expect[d])
      err(sprintf("array %s declares [%d] but its block holds %d items", ctx_path[d], ctx_expect[d], (cnt < 0) ? 0 : cnt))
    for (i = 1; i <= cnt; i++)
      setval(ctx_path[d] "[" (i - 1) "]", parts[i])
    return
  }
  err(sprintf("array %s declares [%d] but its block holds %d items", ctx_path[d], ctx_expect[d], seen))
}

# Classify one key-bearing line. eff_ind is the indent this line occupies for
# the purpose of nesting anything it opens; it differs from the physical indent
# only for the first key on an expanded-array dash-space marker line.
function classify(eff_ind, s, parent,   p, head, tail, v, i, n, fparts, fname, seenf) {
  p = index(s, ":")
  if (p < 2) err("line " lineno " is not classifiable as TOON: [" s "]")
  head = substr(s, 1, p - 1)
  tail = substr(s, p + 1)

  if (is_key(head)) {
    note_root(parent, head)
    if (tail == "") {
      p = path_join(parent, head)
      declare_path(p)
      push("obj", eff_ind, p)
      return
    }
    if (tail == " []") {
      p = path_join(parent, head)
      declare_path(p)
      arr_declared[p] = 0
      return
    }
    if (substr(tail, 1, 1) != " ")
      err("line " lineno ": key " head " must be followed by a colon and one space: [" s "]")
    v = substr(tail, 2)
    if (v == "")
      err("line " lineno ": key " head " has an empty value")
    if (substr(v, 1, 1) == " ")
      err("line " lineno ": value for " head " has leading whitespace; refusing rather than trimming it into validity")
    setval(path_join(parent, head), v)
    return
  }

  if (parse_table_head(head)) {
    if (tail != "") err("line " lineno ": trailing text after a table header: [" s "]")
    n = split_row(HFIELDS, fparts)
    if (n < 1) err("line " lineno ": unreadable field list in table header: [" s "]")
    if (HFIELDS == "") err("line " lineno ": table header declares no fields: [" s "]")
    for (i = 1; i <= n; i++) {
      fname = fparts[i]
      if (!is_key(fname)) err("line " lineno ": table header field " i " is not a valid key: [" fname "]")
      if ((fname) in seenf) err("line " lineno ": table header repeats field " fname)
      seenf[fname] = 1
    }
    note_root(parent, HKEY)
    p = path_join(parent, HKEY)
    declare_path(p)
    push("tab", eff_ind, p)
    ctx_expect[depth] = HCOUNT
    ctx_nfields[depth] = n
    for (i = 1; i <= n; i++) ctx_field[depth SUBSEP i] = fparts[i]
    arr_declared[ctx_path[depth]] = HCOUNT
    return
  }

  if (parse_count_head(head)) {
    if (tail != "") err("line " lineno ": trailing text after a list header: [" s "]")
    note_root(parent, HKEY)
    p = path_join(parent, HKEY)
    declare_path(p)
    push("lst", eff_ind, p)
    ctx_expect[depth] = HCOUNT
    arr_declared[ctx_path[depth]] = HCOUNT
    return
  }

  err("line " lineno " is not classifiable as TOON: [" s "]")
}

BEGIN {
  depth = 0
  ctx_kind[0] = "obj"
  ctx_indent[0] = -2
  ctx_path[0] = ""
  aborted = 0
}

{
  lineno = NR
  line = $0
  if (line ~ /^ *$/)
    err("line " lineno " is blank; a payload that gates a merge must not contain unexplained blank lines")
  if (line ~ /^ *\t/)
    err("line " lineno " indents with a tab; TOON indentation is two spaces per level")
  match(line, /^ */)
  ind = RLENGTH
  if (ind % 2 != 0)
    err("line " lineno " has an odd indent of " ind "; TOON indentation is two spaces per level")
  body = substr(line, ind + 1)

  while (depth > 0 && ind <= ctx_indent[depth]) {
    close_ctx(depth)
    delete ctx_kind[depth]
    depth--
  }
  # The dedent above CLOSES blocks; it never consumes the line that triggered
  # it. Control falls through so this same line is still classified below.

  want = ctx_indent[depth] + 2
  if (ind != want)
    err("line " lineno " sits at indent " ind " but its parent requires " want "; a key at the wrong depth is not the key being looked up")

  k = ctx_kind[depth]

  if (k == "tab") {
    n = split_row(body, fparts)
    if (n < 0) err("line " lineno ": unreadable row in " ctx_path[depth] ": [" body "]")
    if (n != ctx_nfields[depth])
      err(sprintf("line %d: row in %s has %d values but the header declares %d fields", lineno, ctx_path[depth], n, ctx_nfields[depth]))
    ctx_seen[depth]++
    for (i = 1; i <= n; i++)
      setval(ctx_path[depth] "[" (ctx_seen[depth] - 1) "]." ctx_field[depth SUBSEP i], fparts[i])
    next
  }

  if (k == "lst") {
    if (ctx_lmode[depth] == "")
      ctx_lmode[depth] = (substr(body, 1, 2) == "- ") ? "exp" : "blk"
    if (ctx_lmode[depth] == "exp") {
      if (substr(body, 1, 2) != "- ")
        err("line " lineno ": " ctx_path[depth] " is an expanded array, so this line must start a new item with a dash and a space: [" body "]")
      ctx_seen[depth]++
      itempath = ctx_path[depth] "[" (ctx_seen[depth] - 1) "]"
      push("obj", ind, itempath)
      classify(ind + 2, substr(body, 3), itempath)
      next
    }
    if (substr(body, 1, 2) == "- ")
      err("line " lineno ": " ctx_path[depth] " mixes plain items with dash-space items")
    ctx_seen[depth]++
    ctx_items[depth SUBSEP ctx_seen[depth]] = body
    next
  }

  classify(ind, body, ctx_path[depth])
}

END {
  if (aborted) exit 2
  while (depth > 0) {
    close_ctx(depth)
    depth--
  }
  if (aborted) exit 2
  if (MODE == "validate") exit 0
  if (MODE == "rootkey") {
    if (nroot != 1) {
      print "fm-toon: expected exactly one top-level block but found " nroot
      exit 2
    }
    print rootorder[1]
    exit 0
  }
  if (!(TARGET in val)) {
    if (TARGET in arr_declared)
      print "fm-toon: " TARGET " is an array, not a scalar"
    else
      print "fm-toon: no value at path " TARGET
    exit 3
  }
  raw = val[TARGET]
  if (MODE == "bool") {
    # The closed boolean whitelist: exactly these four literal forms, in exactly
    # this case. gh-axi renders booleans as yes/no and TOON canonically uses
    # true/false, so both spellings are exact literals for this producer. A case
    # variant, a quoted form, a number, or anything else is an error - never
    # coerced, and never treated as false just because it is not true.
    if (raw == "true" || raw == "yes") { print "true"; exit 0 }
    if (raw == "false" || raw == "no") { print "false"; exit 0 }
    print "fm-toon: value at " TARGET " is not a boolean: [" raw "]"
    exit 2
  }
  out = decode(raw, TARGET)
  if (aborted) exit 2
  print out
  exit 0
}
'

# fm_toon_query <mode> <path>: run the reader over stdin. Errors are printed by
# awk on stdout and re-emitted here on stderr, which keeps the library portable
# across awk implementations that differ on /dev/stderr support.
fm_toon_query() {
  local mode=$1 path=$2 out rc
  # Capture without disturbing the caller shell options: under set -e the ||
  # branch keeps a non-zero awk exit from killing the caller mid-check.
  out=$(awk -v MODE="$mode" -v TARGET="$path" "$FM_TOON_AWK") && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ -n "$out" ] && printf '%s\n' "$out" >&2
    return "$rc"
  fi
  printf '%s\n' "$out"
  return 0
}

# fm_toon_get <path>: print the decoded scalar at <path>.
fm_toon_get() {
  fm_toon_query get "${1:?fm_toon_get: path required}"
}

# fm_toon_bool <path>: print true or false for a strict boolean at <path>.
fm_toon_bool() {
  fm_toon_query bool "${1:?fm_toon_bool: path required}"
}

# fm_toon_root_key: print the document single top-level key, erroring when the
# document has none or more than one.
fm_toon_root_key() {
  fm_toon_query rootkey ''
}

# fm_toon_validate: parse and validate the whole document, printing nothing.
fm_toon_validate() {
  fm_toon_query validate '' >/dev/null
}
