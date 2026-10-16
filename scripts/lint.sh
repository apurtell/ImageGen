#!/bin/bash
# Banned-pattern checks (IMPLEMENTATION_PLAN.md section 2.7).
#   scripts/lint.sh              lint ImageGen/
#   scripts/lint.sh --self-test  plant one violation per rule in a scratch tree and check each rule fires
set -uo pipefail
source "$(dirname "$0")/env.sh"

GREP=/usr/bin/grep

# Each rule takes the root that contains ImageGen/, prints its violations and returns 1 if any.

# grep_rule <root> <pattern> <dir under ImageGen/>... [-- <path substring to exclude>...]
grep_rule() {
  local root="$1" pattern="$2"; shift 2
  local dirs=() excludes=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do dirs+=("$root/ImageGen/$1"); shift; done
  [ $# -gt 0 ] && shift
  excludes=("$@")
  local existing=()
  for d in "${dirs[@]}"; do [ -e "$d" ] && existing+=("$d"); done
  [ ${#existing[@]} -gt 0 ] || return 0
  local out
  out="$($GREP -rnE --include='*.swift' "$pattern" "${existing[@]}" 2>/dev/null)"
  for ex in ${excludes[@]+"${excludes[@]}"}; do
    out="$(printf '%s\n' "$out" | $GREP -v -F "$ex")"
  done
  out="$(printf '%s\n' "$out" | sed '/^$/d')"
  [ -z "$out" ] && return 0
  printf '%s\n' "$out"
  return 1
}

rule_no_key_in_urls()        { grep_rule "$1" '\?key=|&key=' ""; }
rule_no_full_decode()        { grep_rule "$1" 'UIImage\(data:|UIImage\(contentsOfFile:' "" -- /ImageGen/DebugSupport/; }
rule_no_reencoding_exports() { grep_rule "$1" 'UIImageWriteToSavedPhotosAlbum|jpegData\(|pngData\(' Export Features; }
rule_no_swiftui_in_pure_layers() { grep_rule "$1" '^import SwiftUI' Gemini Imaging Pipeline Security Networking; }
rule_no_print()              { grep_rule "$1" '\bprint\(' "" -- /ImageGen/DebugSupport/; }
rule_no_async_urlsession_for_generation() { grep_rule "$1" '\.data\(for:|\.upload\(for:' Networking Pipeline; }
rule_debug_names_only_via_hooks() {
  grep_rule "$1" '\bLaunchOptions\b|MockGeminiURLProtocol|DemoSeeder|SceneRoute' "" \
    -- /ImageGen/DebugSupport/ /ImageGen/App/DebugHooks.swift
}

rule_no_key_in_activity_log() {
  local root="$1" found=0 out
  [ -d "$root/ImageGen" ] || return 0
  while IFS= read -r -d '' f; do
    out="$(perl -0777 -ne '
      while (/\.(?:begin|step|result)\s*(\((?:[^()]++|(?1))*\))/g) {
        my $args = $1;
        if ($args =~ /(?i)api_?key|keyStore|secretRegistry|x-goog-api-key|\.read\(\)/) {
          my $line = 1 + (substr($_, 0, $-[0]) =~ tr/\n//);
          (my $flat = $args) =~ s/\s+/ /g;
          print "$ARGV:$line: $flat\n";
        }
      }' "$f")"
    if [ -n "$out" ]; then printf '%s\n' "$out"; found=1; fi
  done < <(find "$root/ImageGen" -name '*.swift' -print0)
  return $found
}

rule_debug_guard() {
  local root="$1" found=0 files=() first
  [ -d "$root/ImageGen/DebugSupport" ] && while IFS= read -r -d '' f; do files+=("$f"); done \
    < <(find "$root/ImageGen/DebugSupport" -name '*.swift' -print0)
  [ -f "$root/ImageGen/App/DebugHooks.swift" ] && files+=("$root/ImageGen/App/DebugHooks.swift")
  for f in ${files[@]+"${files[@]}"}; do
    first="$(sed -E '/^[[:space:]]*$/d; /^[[:space:]]*\/\//d' "$f" | head -1)"
    if [ "$first" != "#if DEBUG" ]; then
      echo "$f: first non-comment line is not '#if DEBUG'"
      found=1
    fi
  done
  return $found
}

RULES=(no_key_in_urls no_full_decode no_reencoding_exports no_swiftui_in_pure_layers no_print
       no_async_urlsession_for_generation debug_names_only_via_hooks no_key_in_activity_log debug_guard)

run_all() {
  local root="$1" failed=0 out
  for rule in "${RULES[@]}"; do
    if ! out="$(rule_$rule "$root")"; then
      echo "lint: ${rule//_/-}"
      printf '%s\n' "$out" | sed 's/^/  /'
      failed=1
    fi
  done
  return $failed
}

self_test() {
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  local g="$tmp/ImageGen"
  mkdir -p "$g"/{App,Gemini,Pipeline,Networking,Export,Features,DebugSupport,Support}
  plant() { printf '%s\n' "$2" > "$g/$1"; }

  # A clean tree passes every rule, including the names the rules must not catch.
  plant App/AppDelegate.swift 'func f(_ o: [UIApplication.LaunchOptionsKey: Any]?) {}'
  plant App/DebugHooks.swift $'// hooks\n#if DEBUG\nlet x = LaunchOptions.self\n#endif'
  plant DebugSupport/LaunchOptions.swift $'\n#if DEBUG\nprint("ok"); let i = UIImage(data: d)\n#endif'
  plant Support/Clean.swift $'log.begin("Send", origin: .user,\n  "model \\(m) · prompt \\(private: p)")'
  if ! out="$(run_all "$tmp")"; then
    echo "self-test: FAILED, the clean tree has violations:"; echo "$out"; return 1
  fi

  plant Gemini/Url.swift 'let u = "https://x/models?key=\(k)"'
  plant Features/Decode.swift 'let i = UIImage(data: d)'
  plant Export/Reencode.swift 'let d = image.jpegData(compressionQuality: 1)'
  plant Pipeline/UI.swift 'import SwiftUI'
  plant Networking/Print.swift 'print("debug")'
  plant Networking/Async.swift 'let (d, r) = try await session.data(for: request)'
  plant Features/Hooks.swift 'if LaunchOptions.mock { }'
  plant Support/LogSingle.swift 'log.begin("Validate key", origin: .user, "key \(apiKey)")'
  plant Support/LogMulti.swift $'log.step(a,\n  "retry in 2s",\n  keyStore.read())'
  plant DebugSupport/Unguarded.swift $'// no guard\nenum Mock {}'

  local failed=0 out
  for rule in "${RULES[@]}"; do
    if out="$(rule_$rule "$tmp")"; then
      echo "self-test: rule ${rule//_/-} did not fire"; failed=1
    fi
  done
  # Both activity-log plants must be reported.
  out="$(rule_no_key_in_activity_log "$tmp")"
  for f in LogSingle LogMulti; do
    printf '%s\n' "$out" | $GREP -q "$f.swift" || { echo "self-test: no-key-in-activity-log missed $f.swift"; failed=1; }
  done
  if [ "$failed" -ne 0 ]; then echo "self-test: FAILED"; return 1; fi
  echo "self-test: all ${#RULES[@]} rules fire"
}

case "${1:-}" in
  --self-test) self_test; exit $? ;;
  "") if run_all "$REPO_ROOT"; then echo "lint: clean"; else exit 1; fi ;;
  *) echo "usage: $0 [--self-test]" >&2; exit 2 ;;
esac
