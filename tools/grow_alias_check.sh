#!/usr/bin/env bash
# Lists Odin lines to review by hand for writes through a stale element
# address: `a[i].f = f(...)` takes &a[i] before f runs, so if f grows `a`
# (append, a pool insert) the write lands in the freed buffer; likewise
# `p := &a[i]` held across a call that grows `a`. Prints candidates, not bugs.
#
#   tools/grow_alias_check.sh [dir ...]    (default: .; skips third_party and tests)
set -eu
[ $# -gt 0 ] || set -- .
odin_files() { find "$@" -name '*.odin' -not -path '*/third_party/*' -not -name '*_test.odin'; }
echo "== indexed assignment with a call on the right"
odin_files "$@" | xargs grep -nE '^\s*[A-Za-z_][A-Za-z0-9_.]*\[[^]]+\][][A-Za-z0-9_.]*(\s*,\s*[A-Za-z_][A-Za-z0-9_.]*)*\s*[-+*/|&]?=\s*[^=].*[A-Za-z_]\s*\(' |
	grep -vE '=\s*(f32|f64|u8|u16|u32|u64|i32|i64|int|uint|bool|min|max|clamp|abs|cast|transmute|len)\([^()]*\)\s*$' || true
echo "== element address held in a local"
odin_files "$@" | xargs grep -nE '(:=|,)\s*&[A-Za-z_][A-Za-z0-9_.]*\[[^]]+\]' || true
