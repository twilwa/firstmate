# shellcheck shell=bash
# Shared tasks-axi backend selection and compatibility probe for bootstrap,
# teardown, and secondmate backlog handoff.
# Usage: . bin/fm-tasks-axi-lib.sh
#
# Compatible means tasks-axi --version reports FM_TASKS_AXI_MIN or newer,
# `tasks-axi update --help` exposes --archive-body for recoverable note rewrites,
# and `tasks-axi mv --help` exposes [<id>...] for atomic multi-ID moves required
# by secondmate handoffs.
# FM_TASKS_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
# The feature probes are a separate concern and stay as defense in depth for
# stripped or forked builds that advertise a current version without those flags.
# `config/backlog-backend=manual` opts out of tasks-axi for routine firstmate
# backlog mutations, but validated secondmate handoffs always use `tasks-axi mv`.
# Absent or any other value keeps the default tasks-axi backend path, falling
# back to manual mutation when the tool is not compatible.
# fm_tasks_axi_backend_resolve owns backend precedence: TASKS_AXI_BACKEND when
# set, then the home's private config/tasks.toml selector (a present but
# unreadable or backend-less selector returns 2 rather than falling through),
# then a backend in the working root's .tasks.toml, then one in
# $HOME/.tasks-axi/config.toml, then markdown. Lower-priority sources are read
# only when no earlier source supplies a backend; absent files keep that fallback.
# A detected unreadable or nonregular configuration file, including a dangling
# symlink, returns 2 with a path diagnostic on stderr and no backend on stdout.
# fm_tasks_axi_backend delegates to that resolver and preserves its status;
# callers must check it before selecting backend-specific flags or exemptions.
#
# This file is the single owner of FM_TASKS_AXI_MIN. bin/fm-bootstrap.sh turns a
# failing check into the operator-facing OUTDATED diagnostic, whose requirement
# text renders the check reason below.
#
# COMPATIBILITY VERDICT REUSE. fm_tasks_axi_compatible costs three tasks-axi
# subprocesses, and one session start needs the same verdict twice: once in
# bin/fm-session-start.sh's backlog listing and once in the bin/fm-bootstrap.sh
# child it runs. Two reuse layers collapse that to a single probe:
#   - Within a process the first probe's answer is memoised, together with the
#     reason it reached.
#   - Across ONE process hop, a parent that already holds the verdict passes it
#     in FM_TASKS_AXI_COMPATIBLE=0|1 and its reason in FM_TASKS_AXI_CHECK_REASON.
#     Sourcing this file CONSUMES both variables (they are unset from the
#     environment and kept only as private shell variables), so they reach the
#     child that needs them and never leak onward into a spawned agent's
#     environment, where they could outlive a tasks-axi upgrade. Any verdict
#     other than exactly 0 or 1, and any reason outside the vocabulary below, is
#     ignored and the probe runs normally.
#
# CHECK REASON. A verdict alone cannot render the OUTDATED requirement text: a
# build below the floor is answered by the version, while a build at or above it
# is answered by the capability probe it fails. fm_tasks_axi_compatible_probe
# records the reason while it runs those probes, so fm_tasks_axi_missing_capabilities
# reuses its results instead of paying for the same `--help` probes a second
# time - in the same process or across the hop above. Both capability probes
# always run, so the reason names every one the build lacks rather than the first
# a short-circuit reached. The vocabulary is closed: compatible, version,
# update-archive-body, mv-multi-id, and update-archive-body,mv-multi-id.
#
# Both layers are bounded by process lifetime, so a tasks-axi install or upgrade
# is picked up by the next process rather than being cached to disk.

FM_TASKS_AXI_MIN=0.2.6

FM_TASKS_AXI_COMPATIBLE_MEMO=${FM_TASKS_AXI_COMPATIBLE:-}
unset FM_TASKS_AXI_COMPATIBLE
case "$FM_TASKS_AXI_COMPATIBLE_MEMO" in
  0|1) ;;
  *) FM_TASKS_AXI_COMPATIBLE_MEMO= ;;
esac

FM_TASKS_AXI_CHECK_REASON_MEMO=${FM_TASKS_AXI_CHECK_REASON:-}
unset FM_TASKS_AXI_CHECK_REASON
case "$FM_TASKS_AXI_CHECK_REASON_MEMO" in
  compatible|version|update-archive-body|mv-multi-id|update-archive-body,mv-multi-id) ;;
  *) FM_TASKS_AXI_CHECK_REASON_MEMO= ;;
esac

fm_tasks_axi_version_parts() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi --version 2>/dev/null) || return 1
  printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1
}

fm_tasks_axi_compatible() {
  case "$FM_TASKS_AXI_COMPATIBLE_MEMO" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  if fm_tasks_axi_compatible_probe; then
    FM_TASKS_AXI_COMPATIBLE_MEMO=1
    return 0
  fi
  FM_TASKS_AXI_COMPATIBLE_MEMO=0
  return 1
}

fm_tasks_axi_compatible_probe() {
  local parts major minor patch extra
  local min_major min_minor min_patch min_extra
  local missing
  # Every failing path leaves the version reason behind, so a caller rendering
  # the requirement text never derives it a second time; the passing path below
  # replaces it with the capability result.
  FM_TASKS_AXI_CHECK_REASON_MEMO=version
  parts=$(fm_tasks_axi_version_parts) || return 1
  [ -n "$parts" ] || return 1
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_TASKS_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  if [ "$major" -gt "$min_major" ] ||
    { [ "$major" -eq "$min_major" ] && [ "$minor" -gt "$min_minor" ]; } ||
    { [ "$major" -eq "$min_major" ] && [ "$minor" -eq "$min_minor" ] && [ "$patch" -ge "$min_patch" ]; }; then
    # Both probes run before either result decides the verdict, so the reason
    # names every missing capability rather than the first one reached.
    missing=
    fm_tasks_axi_update_has_archive_body || missing=update-archive-body
    fm_tasks_axi_mv_has_multi_id || missing="${missing:+$missing,}mv-multi-id"
    if [ -n "$missing" ]; then
      FM_TASKS_AXI_CHECK_REASON_MEMO=$missing
      return 1
    fi
    FM_TASKS_AXI_CHECK_REASON_MEMO=compatible
    return 0
  fi
  return 1
}

fm_tasks_axi_update_has_archive_body() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi update --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '--archive-body' >/dev/null
}

fm_tasks_axi_mv_has_multi_id() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi mv --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '[<id>...]' >/dev/null
}

# The reason the compatibility probe reached its verdict: "compatible", "version"
# for an absent, unparseable, or below-floor build, or the capability probes the
# build fails. It reuses the probe's own results and runs the probe only when
# nothing has determined them yet, which is the case when a one-hop verdict
# arrives without its reason.
# The result is printed and left in the memo, so a caller inside a command
# substitution still reuses it within that subshell.
fm_tasks_axi_check_reason() {
  [ -n "$FM_TASKS_AXI_CHECK_REASON_MEMO" ] || fm_tasks_axi_compatible_probe >/dev/null 2>&1 || true
  printf '%s' "$FM_TASKS_AXI_CHECK_REASON_MEMO"
}

# The capabilities this build lacks, rendered with the labels the operator-facing
# requirement text uses and joined by " and ". Empty when the version explains
# the verdict by itself or every capability probe passed.
fm_tasks_axi_missing_capabilities() {
  local missing=
  fm_tasks_axi_check_reason >/dev/null
  case "$FM_TASKS_AXI_CHECK_REASON_MEMO" in
    *update-archive-body*) missing='update --archive-body' ;;
  esac
  case "$FM_TASKS_AXI_CHECK_REASON_MEMO" in
    *mv-multi-id*) missing="${missing:+$missing and }mv multi-ID" ;;
  esac
  printf '%s' "$missing"
}

fm_tasks_axi_backend_from_toml() {  # <toml-path>
  local toml=$1
  [ -f "$toml" ] || return 1
  LC_ALL=C awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    BEGIN { root=1; found=0; single=sprintf("%c", 39) }
    {
      line=$0
      sub(/[[:space:]]*#.*/, "", line)
      line=trim(line)
      if (line ~ /^\[[^]]+\]$/) {
        root=0
        next
      }
      if (root && line ~ /^backend[[:space:]]*=/) {
        sub(/^backend[[:space:]]*=[[:space:]]*/, "", line)
        line=trim(line)
        if ((substr(line, 1, 1) == "\"" && substr(line, length(line), 1) == "\"") ||
            (substr(line, 1, 1) == single && substr(line, length(line), 1) == single)) {
          print substr(line, 2, length(line) - 2)
          found=1
          exit
        }
      }
    }
    END { if (!found) exit 1 }
  ' "$toml"
}

# Read the home selector's string-only fields without evaluating shell text.
# Supports literal strings and basic strings with escaped quotes/backslashes;
# comments start after the closing quote, never inside a path.
# The private selector is strict. "native" mode reads tasks-axi's own project or
# user TOML: unrelated syntax is skipped, while any other spelling of the wanted
# key (dotted, quoted or inline-table) is unsupported and returns 2.
fm_tasks_axi_home_string() {  # <toml-path> <table-or-empty> <key> [native]
  LC_ALL=C awk -v wanted_table="$2" -v wanted_key="$3" -v native="${4:-}" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function bare(s) { gsub(/[[:space:]"]/, "", s); gsub(single, "", s); return s }
    function opens(v,   d) {
      sub(/^[^=]*=[[:space:]]*/, "", v)
      d=substr(v, 1, 3)
      if ((d == "\"\"\"" || d == single single single) && !index(substr(v, 4), d)) return d
      return ""
    }
    BEGIN { table=""; single=sprintf("%c", 39); found=0; bad=0; open="" }
    {
      line=trim($0)
      if (open != "") { if (index(line, open)) open=""; next }
      if (line == "" || line ~ /^#/) next
      if (line ~ /^\[/) {
        if (native && line ~ /^\[\[/) { table="[["; next }
        if (line !~ /^\[[^]]+\][[:space:]]*(#.*)?$/) { if (native) next; bad=1; exit }
        sub(/[[:space:]]*#.*/, "", line)
        table=trim(substr(line, 2, length(line)-2))
        if (native) table=bare(table)
        next
      }
      if (native) {
        if (!index(line, "=")) next
        key=line; sub(/[[:space:]]*=.*/, "", key); key=bare(key)
        key=(table == "" ? key : table "." key)
        simple=(table == wanted_table && line ~ ("^" wanted_key "[[:space:]]*="))
        if ((key == wanted_table "." wanted_key && !simple) || (key == wanted_table && index(line, wanted_key))) { bad=1; exit }
        if (!simple) { open=opens(line); next }
      }
      if (line !~ /^[A-Za-z0-9_-]+[[:space:]]*=/) { bad=1; exit }
      if (table != wanted_table || line !~ ("^" wanted_key "[[:space:]]*=")) next
      if (found++) { bad=1; exit }
      sub(/^[^=]*=[[:space:]]*/, "", line)
      quote=substr(line, 1, 1)
      if (quote != "\"" && quote != single) { bad=1; exit }
      value=""; closed=0
      for (i=2; i<=length(line); i++) {
        c=substr(line, i, 1)
        if (c == quote) { closed=i; break }
        if (quote == "\"" && c == "\\") {
          c=substr(line, ++i, 1)
          if (c != "\\" && c != "\"") { bad=1; exit }
        }
        value=value c
      }
      tail=trim(substr(line, closed+1))
      if (!closed || (tail != "" && substr(tail, 1, 1) != "#") || value ~ /[[:cntrl:]]/) { bad=1; exit }
      result=value
    }
    END { if (bad) exit 2; if (!found) exit 1; print result }
  ' "$1"
}

# Firstmate's private home selector overlays the tracked tasks-axi defaults.
fm_tasks_axi_home_config() {  # <tasks-axi-working-directory>
  printf '%s/tasks.toml\n' "${FM_CONFIG_OVERRIDE:-${FM_HOME:-$1}/config}"
}

# Preserve tasks-axi's precedence below the explicit environment and home overlay.
fm_tasks_axi_backend_resolve() {  # <tasks-axi-working-directory>
  local root=$1 backend
  if [ "${TASKS_AXI_BACKEND+x}" = x ]; then
    printf '%s\n' "$TASKS_AXI_BACKEND"
    return 0
  fi
  local config
  config=$(fm_tasks_axi_home_config "$root")
  if { [ -e "$config" ] || [ -L "$config" ]; }; then
    if [ ! -f "$config" ] || [ ! -r "$config" ]; then
      printf 'tasks-axi backend configuration cannot be read at %s\n' "$config" >&2
      return 2
    fi
    if backend=$(fm_tasks_axi_home_string "$config" '' backend) && [ -n "$backend" ]; then
      printf '%s\n' "$backend"
      return 0
    fi
    printf 'tasks-axi home selector requires one nonempty quoted backend at %s\n' "$config" >&2
    return 2
  fi
  config="$root/.tasks.toml"
  if { [ -d "${config%/*}" ] && [ ! -x "${config%/*}" ]; } ||
    { { [ -e "$config" ] || [ -L "$config" ]; } && { [ ! -f "$config" ] || [ ! -r "$config" ]; }; }; then
    printf 'tasks-axi backend configuration cannot be read at %s\n' "$config" >&2
    return 2
  fi
  if backend=$(fm_tasks_axi_backend_from_toml "$config"); then
    printf '%s\n' "$backend"
    return 0
  fi
  if [ -n "${HOME:-}" ]; then
    config="$HOME/.tasks-axi/config.toml"
    if { [ -d "${config%/*}" ] && [ ! -x "${config%/*}" ]; } ||
      { { [ -e "$config" ] || [ -L "$config" ]; } && { [ ! -f "$config" ] || [ ! -r "$config" ]; }; }; then
      printf 'tasks-axi backend configuration cannot be read at %s\n' "$config" >&2
      return 2
    fi
    if backend=$(fm_tasks_axi_backend_from_toml "$config"); then
      printf '%s\n' "$backend"
      return 0
    fi
  fi
  printf '%s\n' markdown
}

fm_tasks_axi_backend() {  # <tasks-axi-working-directory>
  fm_tasks_axi_backend_resolve "$1"
}

# Apply in the caller, not in the backend resolver's command substitution: every
# tasks-axi invocation (including lifecycle reads/mutations) must see the same
# private overlay. Explicit adapter environment settings retain precedence.
fm_tasks_axi_export_settings() {  # <tasks-axi-working-directory> <resolved-backend>
  local root=$1 backend=$2 config binary path prefix status
  config=$(fm_tasks_axi_home_config "$root")
  if [ -f "$config" ] && [ "$backend" = beads ]; then
    binary=$(fm_tasks_axi_home_string "$config" beads binary); status=$?
    if [ "$status" -eq 2 ]; then
      printf 'tasks-axi home selector has invalid beads.binary at %s\n' "$config" >&2
      return 2
    fi
    path=$(fm_tasks_axi_home_string "$config" beads path); status=$?
    if [ "$status" -eq 2 ]; then
      printf 'tasks-axi home selector has invalid beads.path at %s\n' "$config" >&2
      return 2
    fi
    prefix=$(fm_tasks_axi_home_string "$config" beads prefix); status=$?
    if [ "$status" -eq 2 ]; then
      printf 'tasks-axi home selector has invalid beads.prefix at %s\n' "$config" >&2
      return 2
    fi
    if [ "${TASKS_AXI_BEADS_BINARY+x}" != x ] && [ -n "$binary" ]; then
      export TASKS_AXI_BEADS_BINARY=$binary
    fi
    if [ "${TASKS_AXI_BEADS_PATH+x}" != x ] && [ -n "$path" ]; then
      case "$path" in /*) ;; *) path="${FM_HOME:-$root}/$path" ;; esac
      export TASKS_AXI_BEADS_PATH=$path
    fi
    if [ "${TASKS_AXI_BEADS_PREFIX+x}" != x ] && [ -n "$prefix" ]; then
      export TASKS_AXI_BEADS_PREFIX=$prefix
    fi
  fi
  # With no private selector, leave tasks-axi's native configuration untouched.
  if [ -f "$config" ]; then
    export TASKS_AXI_BACKEND=$backend
  fi
  # --file / TASKS_AXI_FILE would silently select markdown over another backend.
  [ "$backend" = markdown ] || unset TASKS_AXI_FILE
}

# Native tasks-axi precedence below the exported environment: the home's project
# config, then the user config.
fm_tasks_axi_store_beads_setting() { # <key> <environment-value>
  local value=$2 config status
  if [ -z "$value" ]; then
    for config in "$FM_HOME/.tasks.toml" "${HOME:-}/.tasks-axi/config.toml"; do
      [ -f "$config" ] || continue
      status=0
      value=$(fm_tasks_axi_home_string "$config" beads "$1" native) || status=$?
      if [ "$status" -eq 2 ]; then
        printf 'tasks-axi beads.%s cannot be read safely at %s\n' "$1" "$config" >&2
        return 2
      fi
      [ -z "$value" ] || break
    done
  fi
  printf '%s\n' "$value"
}

# Resolve one home's store inside a subshell: private exported settings must not
# leak from the source into the destination (or vice versa). Markdown retains
# Firstmate's explicit data/backlog.md address, including data overrides.
fm_tasks_axi_store_resolve() { # <home> <data> <config>
  FM_HOME=$1
  FM_CONFIG_OVERRIDE=$3
  export FM_HOME FM_CONFIG_OVERRIDE
  FM_TASKS_AXI_STORE_BINARY=
  FM_TASKS_AXI_STORE_BACKEND=$(fm_tasks_axi_backend_resolve "$FM_HOME") || return 2
  fm_tasks_axi_export_settings "$FM_HOME" "$FM_TASKS_AXI_STORE_BACKEND" || return 2
  case "$FM_TASKS_AXI_STORE_BACKEND" in
    markdown) FM_TASKS_AXI_STORE_PATH="$2/backlog.md" ;;
    beads)
      local path
      path=$(fm_tasks_axi_store_beads_setting path "${TASKS_AXI_BEADS_PATH:-}") || return 2
      if [ -z "$path" ]; then
        printf 'tasks-axi beads.path is required for home %s\n' "$FM_HOME" >&2
        return 2
      fi
      case "$path" in /*) ;; *) path="$FM_HOME/$path" ;; esac
      FM_TASKS_AXI_STORE_PATH=$path
      FM_TASKS_AXI_STORE_BINARY=$(fm_tasks_axi_store_beads_setting binary "${TASKS_AXI_BEADS_BINARY:-}") || return 2
      case "$FM_TASKS_AXI_STORE_BINARY" in
        /* | '') ;;
        */*) FM_TASKS_AXI_STORE_BINARY="$FM_HOME/$FM_TASKS_AXI_STORE_BINARY" ;;
      esac
      ;;
    *) printf 'unsupported backlog backend: %s\n' "$FM_TASKS_AXI_STORE_BACKEND" >&2; return 2 ;;
  esac
}

# Beads addresses name a workspace directory or its .db file.
fm_tasks_axi_store_database() { # <backend> <resolved-path>
  case "$1:$2" in
    markdown:* | *.db) printf '%s\n' "$2" ;;
    *) printf '%s/beads.db\n' "$2" ;;
  esac
}

# binary is empty when no setting names one (tasks-axi's own default applies);
# a relative path containing a slash resolves against the home it runs from.
fm_tasks_axi_store_address() ( # <home> <data> <config> <backend|path|binary>
  fm_tasks_axi_store_resolve "$1" "$2" "$3" || return 2
  case "$4" in
    backend) printf '%s\n' "$FM_TASKS_AXI_STORE_BACKEND" ;;
    path) printf '%s\n' "$FM_TASKS_AXI_STORE_PATH" ;;
    binary) printf '%s\n' "$FM_TASKS_AXI_STORE_BINARY" ;;
    *) return 2 ;;
  esac
)

fm_tasks_axi_store_run() ( # <home> <data> <config> <command> [args...]
  fm_tasks_axi_store_resolve "$1" "$2" "$3" || return 2
  shift 3
  local command=$1
  shift
  cd "$FM_HOME" || return 2
  exec tasks-axi "$command" --file "$FM_TASKS_AXI_STORE_PATH" --backend "$FM_TASKS_AXI_STORE_BACKEND" "$@"
)

fm_tasks_axi_markdown_init() ( # <resolved-markdown-path>
  # Preserve the historical home scaffold, not tasks-axi's # Backlog title.
  [ ! -L "$1" ] || return 2
  if [ -e "$1" ]; then
    [ -f "$1" ]
  else
    mkdir -p "$(dirname "$1")" || return 2
    printf '## In flight\n\n## Queued\n\n## Done\n' > "$1"
  fi
)

fm_tasks_axi_store_init() ( # <home> <data> <config>
  fm_tasks_axi_store_resolve "$1" "$2" "$3" || return 2
  if [ "$FM_TASKS_AXI_STORE_BACKEND" = markdown ]; then
    fm_tasks_axi_markdown_init "$FM_TASKS_AXI_STORE_PATH"
  else
    # A read initializes a missing explicit br database. Unlike render, list is
    # supported even when the home has not configured a markdown mirror.
    local output
    if ! output=$(fm_tasks_axi_store_run "$@" list 2>&1); then
      printf '%s\n' "$output" >&2
      return 2
    fi
    fm_tasks_axi_store_refresh "$@"
  fi
)

fm_tasks_axi_store_refresh() ( # <home> <data> <config>
  local output
  if output=$(fm_tasks_axi_store_run "$@" render 2>&1); then return 0; fi
  # render is optional only for a Beads store without a configured mirror.
  # Do not conceal failed database access, malformed config or other failures.
  if printf '%s\n' "$output" | grep -F 'render without beads.mirror' >/dev/null &&
    printf '%s\n' "$output" | grep -Eq '^ *code: UNSUPPORTED$'; then
    return 0
  fi
  printf '%s\n' "$output" >&2
  return 2
)

fm_tasks_axi_markdown_section() { # <file> <key>
  [ -f "$1" ] || return 1
  awk -v key="$2" '
    BEGIN { section = "## Queued" }
    /^##[[:space:]]+/ { section=$0; sub(/^##[[:space:]]+/, "## ", section); sub(/[[:space:]]+$/, "", section); next }
    /^- \[[ x]\] / {
      rest=$0; sub(/^- \[[ x]\] +/, "", rest); id=rest; sub(/[ \t].*/, "", id)
      if (id == key) { print section; found=1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$1"
}

# Missing keys return 1; configuration/backend errors return 2 and must not be
# mistaken for an absent item during whole-request classification.
fm_tasks_axi_store_section() ( # <home> <data> <config> <key>
  fm_tasks_axi_store_resolve "$1" "$2" "$3" || return 2
  if [ "$FM_TASKS_AXI_STORE_BACKEND" = markdown ]; then
    fm_tasks_axi_markdown_section "$FM_TASKS_AXI_STORE_PATH" "$4"
    return $?
  fi
  local database out state
  database=$(fm_tasks_axi_store_database "$FM_TASKS_AXI_STORE_BACKEND" "$FM_TASKS_AXI_STORE_PATH")
  [ -e "$database" ] || return 1
  if ! out=$(fm_tasks_axi_store_run "$1" "$2" "$3" show "$4" 2>&1); then
    if printf '%s\n' "$out" | grep -Eq '^ *code: NOT_FOUND$'; then return 1; fi
    printf '%s\n' "$out" >&2
    return 2
  fi
  state=$(printf '%s\n' "$out" | awk '/^  state: / { sub(/^  state: */, ""); print; exit }')
  case "$state" in
    queued) printf '## Queued\n' ;;
    in_flight) printf '## In flight\n' ;;
    done) printf '## Done\n' ;;
    *) printf 'tasks-axi show %s returned invalid state: %s\n' "$4" "$state" >&2; return 2 ;;
  esac
)

fm_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

fm_backlog_backend_manual() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = manual ]
}

fm_tasks_axi_backend_available() {
  local config_dir=$1
  fm_backlog_backend_manual "$config_dir" && return 1
  fm_tasks_axi_compatible
}
