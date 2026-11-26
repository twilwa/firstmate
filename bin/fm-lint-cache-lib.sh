# shellcheck shell=bash
# fm-lint-cache-lib.sh - per-root ShellCheck pass cache for bin/fm-lint.sh.
#
# Sourced only by bin/fm-lint.sh, which owns when the cache is consulted; this
# library owns the key, the entry format, and the audit that proves a key
# stale. Every caller of fm-lint.sh (local changed-file mode, CI partitions,
# the no-mistakes lint step, explicit paths) gets the same keying.
#
# Key. One SHA-256 per root over:
#   - the root path as passed and the exact ShellCheck flags of the root's one
#     final attempt (a known-heavy root keys on its no-source flags);
#   - a context hash: the ShellCheck binary's SHA-256 and full --version text,
#     the content of every lint-definition file fm-lint.sh names, the run scope
#     (hosted or local, so the two never share an entry), uname -s/-m, and the
#     LC_ALL, LC_CTYPE, LANG, and GHCRTS environment;
#   - the root's transitive source closure, over-approximated: every
#     `# shellcheck source=` value and every literal fragment of a `source` or
#     `.` command's arguments (ShellCheck strips a leading variable, so
#     "$D/x.sh" reads as x.sh), after joining backslash continuations, resolved
#     against the working directory, the root's directory, the referencing
#     file's directory, and every `source-path=` value or -P flag (SCRIPTDIR
#     read as both the root's and the referencing file's directory), iterated
#     to a fixpoint. Each existing regular file adds its path and content hash
#     and is parsed in turn; each absent candidate adds a missing marker, so
#     creating a file ShellCheck would now find also misses; a directory or
#     special file adds a marker. An unreadable closure file, a missing --norc,
#     or an unreadable root makes the root uncacheable: it is linted every run.
#
# Entries. A cache hit is only ever a recorded pass for that exact key: only a
# root whose final attempt exited 0 with reason ok or known-heavy is stored,
# never findings, a timeout, a memory failure, or a memory-fallback pass whose
# verdict depends on that run's memory. A pass is stored only when the key
# recomputed after linting, from the flags the worker actually ran, equals the
# key looked up before it, so an edit during the run cannot record a pass for
# content that was never linted. An entry is one file
# <dir>/fm-lint-cache-v1/<key> whose exact bytes are re-derived and compared
# on every read; any mismatch, an unreadable entry, or an unreadable cache
# directory discards every hit for the run, so the whole selection is linted.
# Hits refresh the entry's mtime and a run prunes entries unused for
# FM_LINT_CACHE_MAX_AGE_DAYS (default 14).
#
# Audit. The scheduled uncached run (fm-lint.sh --audit-cache/--audit-record)
# lints every root without reading or writing the cache, then reports each
# root with findings whose current key the cache records as a pass, or that a
# cached run's sidecar recorded as a hit or stored pass, as a stale key by name.

# Internal: the Perl helper. Modes read tab-separated requests on stdin, one
# per root, with flags joined by \x1f:
#   lookup <dir> <context>   index path flags         -> index status key detail
#   store  <dir> <context>   index path flags key why -> index status key
#   audit  <dir> <context>   index path flags         -> index status key
#   prune  <dir> <days>
read -r -d '' FM_LINT_CACHE_PERL <<'PERL' || true
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Basename qw(dirname);
use Cwd qw(getcwd realpath);

my ($mode, $dir) = (shift @ARGV, shift @ARGV);
my $entries = "$dir/fm-lint-cache-v1";

if ($mode eq 'prune') {
  my $days = shift @ARGV;
  opendir(my $dh, $entries) or exit 0;
  my $now = time;
  for my $name (readdir $dh) {
    my $path = "$entries/$name";
    my @st = lstat $path or next;
    next unless -f _;
    my $age = $now - $st[9];
    if ($name =~ /\A[0-9a-f]{64}\z/) {
      unlink $path if $age > $days * 86400;
    } elsif ($name =~ /\A\.tmp\./) {
      unlink $path if $age > 86400;
    }
  }
  exit 0;
}

my $context_file = shift @ARGV;
my $context = Digest::SHA->new(256);
my %file_sha;
sub file_sha {
  my ($path) = @_;
  return $file_sha{$path} if exists $file_sha{$path};
  my $sha;
  if (-f $path && open(my $fh, '<', $path)) {
    binmode $fh;
    my $d = Digest::SHA->new(256);
    $sha = eval { $d->addfile($fh); $d->hexdigest };
    close $fh;
  }
  return $file_sha{$path} = $sha;
}
open(my $cf, '<', $context_file) or die "fm-lint cache: cannot read context: $!\n";
while (my $line = <$cf>) {
  chomp $line;
  if ($line =~ /\Ahashfile (\S+) (.+)\z/) {
    my ($label, $path) = ($1, $2);
    my $sha = file_sha($path);
    if (!defined $sha) {
      die "fm-lint cache: cannot hash $label $path\n" if -e $path || $label eq 'shellcheck-binary';
      $sha = 'missing';
    }
    $context->add("$label\0$sha\n");
  } else {
    $context->add("$line\n");
  }
}
close $cf;
my $context_hash = $context->hexdigest;

my %refs;
sub file_refs {
  my ($path) = @_;
  return $refs{$path} if exists $refs{$path};
  open(my $fh, '<', $path) or return $refs{$path} = undef;
  binmode $fh;
  local $/;
  my $text = <$fh>;
  close $fh;
  $text = '' unless defined $text;
  $text =~ s/\\\r?\n//g;
  my (@sources, @paths);
  for my $line (split /\n/, $text) {
    if ($line =~ /#.*\bshellcheck\b/) {
      while ($line =~ /\bsource=(\S+)/g) { my $v = $1; $v =~ s/\A(['"])(.*)\1\z/$2/; push @sources, ['directive', $v]; }
      while ($line =~ /\bsource-path=(\S+)/g) { my $v = $1; $v =~ s/\A(['"])(.*)\1\z/$2/; push @paths, $v; }
    }
    next if $line =~ /\A\s*#/;
    while ($line =~ /(?:\A|[\s;&|(){}!`"'])(?:source|\.)[ \t]+/g) {
      my $rest = substr($line, pos($line));
      $rest =~ s/\$\{[^}]*\}|\$[A-Za-z_]\w*|\$[0-9@*#?\$!-]/ /g;
      for my $fragment (split /[\s"'`\$(){};|&<>\\]+/, $rest) {
        push @sources, ['command', $fragment] if length $fragment;
      }
    }
  }
  return $refs{$path} = [\@sources, \@paths];
}

sub with_scriptdir {
  my ($value, @dirs) = @_;
  return ($value) unless $value =~ /SCRIPTDIR/;
  return map { (my $v = $value) =~ s/SCRIPTDIR/$_/g; $v } @dirs;
}

sub join_path {
  my ($base, $rel) = @_;
  return $rel if $base eq '.';
  return "$base/$rel";
}

my $cwd = getcwd();
# An existing closure file's identity is its real path, relative to the working
# directory when it lies below it, so `..` spellings cannot grow the walk.
my %canonical;
sub canonical {
  my ($path) = @_;
  return $canonical{$path} if exists $canonical{$path};
  my $real = realpath($path);
  return $canonical{$path} = undef unless defined $real;
  $real = substr($real, length($cwd) + 1) if index($real, "$cwd/") == 0;
  return $canonical{$path} = $real;
}

my %kind;
sub path_kind {
  my ($path) = @_;
  return $kind{$path} if exists $kind{$path};
  my $k;
  if (!-e $path) { $k = 'missing' }
  elsif (-d _) { $k = 'dir' }
  elsif (-f _) { $k = 'file' }
  else { $k = 'special' }
  return $kind{$path} = $k;
}

sub root_key {
  my ($root, $flags) = @_;
  my @flags = length $flags ? split(/\x1f/, $flags, -1) : ();
  return (undef, 'flags lack --norc') unless grep { $_ eq '--norc' } @flags;
  return (undef, 'root is not a readable regular file') unless path_kind($root) eq 'file' && defined file_sha($root);
  my $root_dir = dirname($root);
  my %bases;
  for (my $i = 0; $i < @flags; $i++) {
    my $value;
    if ($flags[$i] =~ /\A(?:-P|--source-path)\z/ && $i + 1 < @flags) { $value = $flags[++$i] }
    elsif ($flags[$i] =~ /\A--source-path=(.*)\z/s) { $value = $1 }
    elsif ($flags[$i] =~ /\A-P(.+)\z/s) { $value = $1 }
    next unless defined $value;
    $bases{$_} = 1 for with_scriptdir($value, $root_dir);
  }
  my (%material, %seen);
  while (1) {
    my $known = scalar keys %bases;
    %material = ();
    %seen = ($root => 1);
    $material{"file\0$root\0" . file_sha($root)} = 1;
    my @queue = ($root);
    while (@queue) {
      my $file = shift @queue;
      my $refs = file_refs($file);
      return (undef, "cannot read $file") unless defined $refs;
      my $file_dir = dirname($file);
      for my $value (@{$refs->[1]}) {
        for my $base (with_scriptdir($value, $root_dir, $file_dir)) {
          $bases{$base} = 1;
          $bases{join_path($file_dir, $base)} = 1 unless $base =~ m{\A/};
        }
      }
      my @dirs = ('.', $root_dir, $file_dir, sort keys %bases);
      for my $ref (@{$refs->[0]}) {
        my ($type, $value) = @$ref;
        my @candidates;
        my @forms = ($value);
        push @forms, $1 if $type eq 'command' && $value =~ m{\A~[^/]*/(.+)\z};
        for my $form (map { with_scriptdir($_, $root_dir, $file_dir) } @forms) {
          if ($form =~ m{\A/}) {
            push @candidates, $form;
            next unless $type eq 'command';
            (my $rel = $form) =~ s{\A/+}{};
            next unless length $rel;
            push @candidates, map { join_path($_, $rel) } @dirs;
          } else {
            push @candidates, map { join_path($_, $form) } @dirs;
          }
        }
        for my $candidate (@candidates) {
          my $k = path_kind($candidate);
          if ($k eq 'file') {
            my $real = canonical($candidate);
            my $sha = defined $real ? file_sha($real) : undef;
            return (undef, "cannot read $candidate") unless defined $sha;
            $material{"file\0$real\0$sha"} = 1;
            push @queue, $real unless $seen{$real}++;
          } else {
            $material{"$k\0$candidate"} = 1;
          }
        }
      }
    }
    last if scalar(keys %bases) == $known;
  }
  my $d = Digest::SHA->new(256);
  $d->add("fm-lint-cache-key-v1\n", "context\0$context_hash\n", "root\0$root\n", "flags\0" . join("\0", @flags) . "\n");
  $d->add("$_\n") for sort keys %material;
  return ($d->hexdigest, '');
}

sub entry_text {
  my ($key, $root, $reason) = @_;
  my $body = "fm-lint-cache-entry-v1\nkey $key\nverdict pass\nreason $reason\nroot $root\n";
  return $body . 'check ' . sha256_hex($body) . "\n";
}

# Returns ('none'), ('pass', reason), or ('corrupt', detail).
sub read_entry {
  my ($key, $root) = @_;
  my $path = "$entries/$key";
  return ('none') unless -e $path || -l $path;
  open(my $fh, '<', $path) or return ('corrupt', "unreadable entry $path");
  binmode $fh;
  my $text = '';
  my $n = read($fh, $text, 8192);
  close $fh;
  return ('corrupt', "unreadable entry $path") unless defined $n;
  for my $reason ('ok', 'known-heavy') {
    return ('pass', $reason) if $text eq entry_text($key, $root, $reason);
  }
  return ('corrupt', "malformed entry $path");
}

while (my $line = <STDIN>) {
  chomp $line;
  my @f = split /\t/, $line, -1;
  my ($index, $root, $flags) = @f;
  my ($key, $why) = root_key($root, $flags);
  if ($mode eq 'lookup' || $mode eq 'audit') {
    if (!defined $key) { print "$index\tuncacheable\t-\t$why\n"; next; }
    my ($state, $detail) = read_entry($key, $root);
    if ($mode eq 'audit') {
      print "$index\t" . ($state eq 'pass' ? 'pass-recorded' : $state) . "\t$key\t" . ($detail // '') . "\n";
    } elsif ($state eq 'pass') {
      utime(undef, undef, "$entries/$key");
      print "$index\thit\t$key\t$detail\n";
    } else {
      print "$index\t" . ($state eq 'none' ? 'miss' : 'corrupt') . "\t$key\t" . ($detail // '') . "\n";
    }
  } elsif ($mode eq 'store') {
    my ($prior, $reason) = @f[3, 4];
    if (!defined $key) { print "$index\tuncacheable\t-\n"; next; }
    if ($key ne $prior) { print "$index\tchanged\t$key\n"; next; }
    if ($reason ne 'ok' && $reason ne 'known-heavy') { print "$index\tnot-a-pass\t$key\n"; next; }
    my $ok = -d $entries || mkdir($entries) || -d $entries;
    my $tmp = "$entries/.tmp.$$.$key";
    if ($ok && open(my $out, '>', $tmp)) {
      binmode $out;
      $ok = (print {$out} entry_text($key, $root, $reason)) && close($out) && rename($tmp, "$entries/$key");
      unlink $tmp unless $ok;
    } else {
      $ok = 0;
    }
    print "$index\t" . ($ok ? 'stored' : 'error') . "\t$key\n";
  } else {
    die "fm-lint cache: unknown mode $mode\n";
  }
}
PERL

# fm_lint_cache_write_context <file> <shellcheck-bin> <scope> <definition-path>...:
# write the run-wide context the Perl helper folds into every key.
fm_lint_cache_write_context() {
  local file=$1 bin=$2 scope=$3 definition
  shift 3
  {
    printf 'fm-lint-cache-context-v1\n'
    printf 'scope %s\n' "$scope"
    printf 'platform %s %s\n' "$(uname -s)" "$(uname -m)"
    printf 'env LC_ALL=%s\n' "${LC_ALL-<unset>}"
    printf 'env LC_CTYPE=%s\n' "${LC_CTYPE-<unset>}"
    printf 'env LANG=%s\n' "${LANG-<unset>}"
    printf 'env GHCRTS=%s\n' "${GHCRTS-<unset>}"
    printf 'hashfile shellcheck-binary %s\n' "$bin"
    "$bin" --version 2>&1 | sed 's/^/shellcheck-version /'
    for definition in "$@"; do
      printf 'hashfile definition:%s %s\n' "$definition" "$definition"
    done
  } > "$file"
}

# fm_lint_cache_helper <mode> <dir> <arg>: run the Perl helper on stdin.
fm_lint_cache_helper() {
  "${PERL_BIN:-perl}" -e "$FM_LINT_CACHE_PERL" "$@"
}

# The orchestration below runs inside bin/fm-lint.sh's main process and reads
# its run globals (ROOTS, ROOT_COUNT, TMP_ROOT, OUTPUT_DIR, ROOTS_LOG,
# SHELLCHECK_BIN, LOCAL_RUN, the analysis-mode and bounds settings, NO_CACHE,
# and the audit inputs).

fm_lint_cache_scope() {
  if [ "$LOCAL_RUN" -eq 1 ]; then printf 'local\n'; else printf 'hosted\n'; fi
}

fm_lint_cache_warn() {
  printf 'fm-lint.sh: lint cache: %s\n' "$1" >&2
  [ "${GITHUB_ACTIONS:-}" != true ] || printf '::warning title=fm-lint cache::%s\n' "$1"
}

# fm_lint_cache_requests <out>: one helper request per selected root, keyed on
# the flags fm_lint_root_final_args predicts for this run's mode and bounds.
fm_lint_cache_requests() {
  local out=$1 index=1 path IFS=$'\037'
  # shellcheck disable=SC2034 # Read by fm-lint.sh's flag builders below.
  local FM_LINT_INTERNAL_FOLLOW_SOURCES=$FOLLOW_SOURCES FM_LINT_INTERNAL_EXCLUDE=$EXCLUDE_CODES
  # shellcheck disable=SC2034 # Read by fm-lint.sh's flag builders below.
  local FM_LINT_INTERNAL_FAST=$FAST FM_LINT_INTERNAL_BOUNDED=$BOUND_MECH
  # shellcheck disable=SC2034 # Read by fm-lint.sh's flag builders below.
  local FM_LINT_INTERNAL_MEMORY_KIB=$ROOT_MEMORY_KIB
  fm_lint_build_worker_args
  for path in "${ROOTS[@]}"; do
    fm_lint_root_final_args "$path"
    printf '%s\t%s\t%s\n' "$index" "$path" "${FM_LINT_ROOT_ARGS[*]}"
    index=$((index + 1))
  done > "$out"
}

# fm_lint_cache_ran_flags <shard> <index>: the flags a worker recorded for the
# root it ran, joined for a helper request.
fm_lint_cache_ran_flags() {
  local file="$OUTPUT_DIR/root.$1.$2.args" IFS=$'\037'
  local -a flags
  [ -r "$file" ] || return 1
  mapfile -t flags < "$file"
  printf '%s' "${flags[*]}"
}

# Look up every selected root before any worker starts. Sets
# FM_LINT_CACHE_STATE (off, on, bypassed, or disabled), the per-index
# FM_LINT_CACHE_HIT, FM_LINT_CACHE_KEY, and FM_LINT_CACHE_STATUS arrays, and
# LINT_COUNT, the roots left for the workers.
fm_lint_cache_begin() {
  local out index status key detail corrupt=0 hits=0
  FM_LINT_CACHE_STATE=off
  FM_LINT_CACHE_HIT=()
  FM_LINT_CACHE_KEY=()
  FM_LINT_CACHE_STATUS=()
  LINT_COUNT=$ROOT_COUNT
  if [ "$NO_CACHE" -eq 1 ]; then
    FM_LINT_CACHE_STATE=bypassed
    printf 'fm-lint.sh: lint cache bypassed; every selected root is linted and nothing is recorded\n' >&2
    return 0
  fi
  [ -n "${FM_LINT_CACHE_DIR:-}" ] || return 0
  FM_LINT_CACHE_STATE=disabled
  if [ -e "$FM_LINT_CACHE_DIR" ] \
    && ! { [ -d "$FM_LINT_CACHE_DIR" ] && [ -r "$FM_LINT_CACHE_DIR" ] && [ -x "$FM_LINT_CACHE_DIR" ]; }; then
    fm_lint_cache_warn "$FM_LINT_CACHE_DIR is not a readable directory; linting every root"
    return 0
  fi
  [ "$ROOT_COUNT" -gt 0 ] || { FM_LINT_CACHE_STATE=on; return 0; }
  fm_lint_cache_write_context "$TMP_ROOT/cache.context" "$SHELLCHECK_BIN" "$(fm_lint_cache_scope)" \
    "${FM_LINT_DEFINITION_FILES[@]}"
  fm_lint_cache_requests "$TMP_ROOT/cache.requests"
  out="$TMP_ROOT/cache.lookup"
  if ! fm_lint_cache_helper lookup "$FM_LINT_CACHE_DIR" "$TMP_ROOT/cache.context" \
    < "$TMP_ROOT/cache.requests" > "$out" 2> "$out.err" \
    || [ "$(wc -l < "$out" | tr -d '[:space:]')" -ne "$ROOT_COUNT" ]; then
    fm_lint_cache_warn "lookup failed ($(head -n1 "$out.err")); linting every root"
    return 0
  fi
  FM_LINT_CACHE_STATE=on
  while IFS=$'\t' read -r index status key detail; do
    FM_LINT_CACHE_KEY[index]=$key
    FM_LINT_CACHE_STATUS[index]=$status
    case "$status" in
      hit) hits=$((hits + 1)) ;;
      corrupt)
        corrupt=1
        fm_lint_cache_warn "$detail; discarding every hit and linting every root"
        ;;
    esac
  done < "$out"
  [ "$corrupt" -eq 0 ] || return 0
  for index in "${!FM_LINT_CACHE_STATUS[@]}"; do
    [ "${FM_LINT_CACHE_STATUS[index]}" = hit ] || continue
    FM_LINT_CACHE_HIT[index]=1
    [ "$PROGRESS" != 1 ] \
      || printf 'fm-lint: cache hit %s (recorded pass, key %s)\n' "${ROOTS[index - 1]}" "${FM_LINT_CACHE_KEY[index]}" >&2
  done
  # shellcheck disable=SC2034 # fm-lint.sh starts workers only for these roots.
  LINT_COUNT=$((ROOT_COUNT - hits))
}

# After the workers: record every root whose final attempt passed with reason
# ok or known-heavy, from the flags it actually ran, then prune old entries.
fm_lint_cache_finish() {
  local kind index path shard rc reason flags out status key
  [ "$FM_LINT_CACHE_STATE" = on ] && [ -s "$ROOTS_LOG" ] || return 0
  : > "$TMP_ROOT/cache.store"
  # shellcheck disable=SC2034 # The roots log's unused middle columns.
  while IFS=$'\t' read -r kind index path shard _ _ _ _ rc reason _; do
    [ "$kind" = end ] && [ "$rc" = 0 ] || continue
    case "$reason" in ok|known-heavy) ;; *) continue ;; esac
    key=${FM_LINT_CACHE_KEY[index]:--}
    [ "$key" != - ] || continue
    flags=$(fm_lint_cache_ran_flags "$shard" "$index") || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$index" "$path" "$flags" "$key" "$reason" >> "$TMP_ROOT/cache.store"
  done < "$ROOTS_LOG"
  out="$TMP_ROOT/cache.stored"
  if [ -s "$TMP_ROOT/cache.store" ]; then
    mkdir -p "$FM_LINT_CACHE_DIR" 2>/dev/null || true
    fm_lint_cache_helper store "$FM_LINT_CACHE_DIR" "$TMP_ROOT/cache.context" \
      < "$TMP_ROOT/cache.store" > "$out" 2> "$out.err" \
      || fm_lint_cache_warn "recording passes failed ($(head -n1 "$out.err"))"
    while IFS=$'\t' read -r index status key; do
      case "$status" in
        stored) FM_LINT_CACHE_STATUS[index]=stored ;;
        changed) fm_lint_cache_warn "${ROOTS[index - 1]} changed while it was linted; its pass was not recorded" ;;
        *) fm_lint_cache_warn "could not record the pass for ${ROOTS[index - 1]} ($status)" ;;
      esac
    done < "$out"
  fi
  fm_lint_cache_helper prune "$FM_LINT_CACHE_DIR" "${FM_LINT_CACHE_MAX_AGE_DAYS:-14}" 2>/dev/null || true
}

# Print the run's hit and miss counts and, beside --telemetry, write the
# per-root cache sidecar a later audit compares against.
fm_lint_cache_report() {  # <sidecar-path-or-empty>
  local sidecar=$1 index hits=0 misses=0 stored=0 uncacheable=0 status
  for ((index = 1; index <= ROOT_COUNT; index++)); do
    status=${FM_LINT_CACHE_STATUS[index]:-}
    case "$status" in
      hit) [ -n "${FM_LINT_CACHE_HIT[index]:-}" ] && hits=$((hits + 1)) || misses=$((misses + 1)) ;;
      stored) stored=$((stored + 1)); misses=$((misses + 1)) ;;
      uncacheable) uncacheable=$((uncacheable + 1)) ;;
      *) misses=$((misses + 1)) ;;
    esac
  done
  # shellcheck disable=SC2034 # fm-lint.sh writes these into its telemetry.
  FM_LINT_CACHE_HITS=$hits FM_LINT_CACHE_MISSES=$misses FM_LINT_CACHE_STORED=$stored
  if [ "$FM_LINT_CACHE_STATE" = on ]; then
    printf 'fm-lint.sh: lint cache: hits=%s misses=%s stored=%s uncacheable=%s scope=%s\n' \
      "$hits" "$misses" "$stored" "$uncacheable" "$(fm_lint_cache_scope)" >&2
  fi
  [ -n "$sidecar" ] || return 0
  {
    printf 'format\tfm-lint-cache-v1\n'
    printf 'meta\tstate\t%s\n' "$FM_LINT_CACHE_STATE"
    printf 'meta\tscope\t%s\n' "$(fm_lint_cache_scope)"
    printf 'meta\tgit_head\t%s\n' "$(git rev-parse HEAD 2>/dev/null || printf 'unavailable')"
    for ((index = 1; index <= ROOT_COUNT; index++)); do
      status=${FM_LINT_CACHE_STATUS[index]:-linted}
      [ "$status" != hit ] || [ -n "${FM_LINT_CACHE_HIT[index]:-}" ] || status=relinted
      printf 'root\t%s\t%s\t%s\n' "${ROOTS[index - 1]}" "$status" "${FM_LINT_CACHE_KEY[index]:--}"
    done
    printf 'meta\thits\t%s\n' "$hits"
    printf 'meta\tmisses\t%s\n' "$misses"
    printf 'meta\tstored\t%s\n' "$stored"
    printf 'meta\tuncacheable\t%s\n' "$uncacheable"
  } > "$sidecar" || fm_lint_cache_warn "could not write the cache sidecar $sidecar"
}

fm_lint_cache_stale() {  # <key> <root> <source>
  local message="STALE LINT CACHE KEY $1: $2 has findings in this uncached run, but $3 recorded a pass for that key"
  printf 'fm-lint.sh: %s\n' "$message" >&2
  [ "${GITHUB_ACTIONS:-}" != true ] || printf '::error title=Stale lint cache key::%s\n' "$message"
}

# The uncached audit: compare every root with findings in this run against the
# recorded passes of AUDIT_CACHE and of each AUDIT_RECORDS sidecar. Sets
# FM_LINT_CACHE_STALE to the number of stale keys proven.
fm_lint_cache_audit() {
  local kind index path shard reason flags record rpath rstatus rkey status key detail
  local -A failing=()
  FM_LINT_CACHE_STALE=0
  [ -n "$AUDIT_CACHE" ] || [ "${#AUDIT_RECORDS[@]}" -gt 0 ] || return 0
  : > "$TMP_ROOT/cache.audit"
  if [ -s "$ROOTS_LOG" ]; then
    # shellcheck disable=SC2034 # The roots log's unused middle columns.
    while IFS=$'\t' read -r kind index path shard _ _ _ _ _ reason _; do
      [ "$kind" = end ] && [ "$reason" = findings ] || continue
      failing[$path]=1
      flags=$(fm_lint_cache_ran_flags "$shard" "$index") || continue
      printf '%s\t%s\t%s\n' "$index" "$path" "$flags" >> "$TMP_ROOT/cache.audit"
    done < "$ROOTS_LOG"
  fi
  if [ -n "$AUDIT_CACHE" ] && [ -s "$TMP_ROOT/cache.audit" ]; then
    fm_lint_cache_write_context "$TMP_ROOT/cache.context" "$SHELLCHECK_BIN" "$(fm_lint_cache_scope)" \
      "${FM_LINT_DEFINITION_FILES[@]}"
    if fm_lint_cache_helper audit "$AUDIT_CACHE" "$TMP_ROOT/cache.context" \
      < "$TMP_ROOT/cache.audit" > "$TMP_ROOT/cache.audited" 2> "$TMP_ROOT/cache.audited.err"; then
      while IFS=$'\t' read -r index status key detail; do
        case "$status" in
          pass-recorded)
            fm_lint_cache_stale "$key" "${ROOTS[index - 1]}" "the cache at $AUDIT_CACHE"
            FM_LINT_CACHE_STALE=$((FM_LINT_CACHE_STALE + 1))
            ;;
          corrupt) fm_lint_cache_warn "audit found $detail" ;;
        esac
      done < "$TMP_ROOT/cache.audited"
    else
      fm_lint_cache_warn "could not audit $AUDIT_CACHE ($(head -n1 "$TMP_ROOT/cache.audited.err"))"
    fi
  fi
  for record in "${AUDIT_RECORDS[@]}"; do
    if [ ! -r "$record" ]; then
      fm_lint_cache_warn "cannot read the cached run's sidecar $record"
      continue
    fi
    while IFS=$'\t' read -r kind rpath rstatus rkey; do
      [ "$kind" = root ] || continue
      case "$rstatus" in hit|stored) ;; *) continue ;; esac
      [ -n "${failing[$rpath]:-}" ] || continue
      fm_lint_cache_stale "$rkey" "$rpath" "the cached run's sidecar $record"
      FM_LINT_CACHE_STALE=$((FM_LINT_CACHE_STALE + 1))
    done < "$record"
  done
}
