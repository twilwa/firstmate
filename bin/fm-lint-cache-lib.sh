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
#     LC_ALL, LC_CTYPE, LANG, and GHCRTS environment. fm-lint.sh clears
#     BASH_ENV and strips SHELLCHECK_OPTS at every ShellCheck exec, so these
#     flags are the whole invocation. A ShellCheck that resolves to a script
#     wrapper, or to anything but a regular executable file, disables the
#     cache: its behavior cannot be hashed;
#   - the root's transitive source closure, over-approximated. Every
#     `# shellcheck source=` and `source-path=` value (quoted or bare) counts,
#     and every `source`/`.` argument, tokenized like ShellCheck 0.11.0's
#     readSource: the first word (after `--`, or `-p` and its value) read as a
#     literal string, or a literal /tail after one leading expansion
#     ("$D/x.sh" reads as ./x.sh). Any other word, and a `~/` path, is one
#     ShellCheck never follows (SC1090), so it reads no file. Candidates are
#     resolved against the working directory, the root's directory, the
#     referencing file's directory, and every source-path value (SCRIPTDIR
#     read as both the root's and the referencing file's directory), iterated
#     to a fixpoint. Like ShellCheck, an absolute path is also resolved
#     against each of those with its leading slash stripped. Each candidate
#     adds its lexical path with what it resolves to - a regular file's real
#     path and content hash (that file is
#     parsed in turn), or a missing, directory, or special marker - so
#     creating a file, swapping a symlink, or changing which candidate wins
#     all miss.
#   A root is uncacheable, and is linted every run, whenever the key cannot be
#   proven complete: a source argument the tokenizer cannot delimit with no
#   source= directive on the line or the comment lines just above it, a -P or
#   --source-path flag, an unreadable closure file, a missing --norc, or an
#   unreadable root.
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
# Only a readable regular file is an entry; a symlink, FIFO, or other node is
# corrupt, and the reader opens entries without blocking. Hits refresh the
# entry's mtime and a run prunes entries unused for 14 days.
#
# Summary. Every run prints "lint cache: hits=N misses=N stored=N
# uncacheable=N scope=local|hosted state=off|on|disabled|bypassed", where
# misses is every selected root that was linted (root count minus hits) and
# uncacheable is the subset of misses that can never be recorded.
#
# Audit. The scheduled uncached run (fm-lint.sh --audit-cache/--audit-record)
# lints every root without reading or writing the cache, then reports each
# root with findings whose current key the cache records as a pass, or that a
# same-commit cached run's sidecar recorded as a hit or stored pass, as a stale
# key by name. A root with findings that neither source attributes is reported
# as AUDIT INCOMPLETE with its commit, partition, and recomputed candidate key,
# never claimed as the key a cached run replayed.

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
use Fcntl qw(O_RDONLY O_NONBLOCK);

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
    if ($label eq 'shellcheck-binary') {
      my $real = realpath($path);
      die "fm-lint cache: ShellCheck at $path has no real path\n" unless defined $real;
      die "fm-lint cache: ShellCheck at $real is not a regular executable file\n" unless -f $real && -x _;
      open(my $bin, '<', $real) or die "fm-lint cache: cannot read ShellCheck at $real\n";
      binmode $bin;
      my $magic = '';
      read($bin, $magic, 2);
      close $bin;
      die "fm-lint cache: ShellCheck at $real is a script wrapper, so its behavior cannot be hashed\n" if $magic eq '#!';
      $path = $real;
    }
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

# The end offset of the expansion starting at $s[$i] ($..., ${...}, $(...),
# or `...`), or undef when it cannot be delimited.
sub expansion_end {
  my ($s, $i) = @_;
  my $n = length $s;
  my $c = substr($s, $i, 1);
  if ($c eq '`') {
    for (my $j = $i + 1; $j < $n; $j++) {
      my $d = substr($s, $j, 1);
      if ($d eq '\\') { $j++; next }
      return $j + 1 if $d eq '`';
    }
    return undef;
  }
  my $next = substr($s, $i + 1, 1);
  if ($next eq '(' || $next eq '{') {
    my ($open, $close) = $next eq '(' ? ('(', ')') : ('{', '}');
    my $depth = 0;
    for (my $j = $i + 1; $j < $n; $j++) {
      my $d = substr($s, $j, 1);
      if ($d eq '\\') { $j++; next }
      if ($d eq "'") { my $k = index($s, "'", $j + 1); return undef if $k < 0; $j = $k; next }
      if ($d eq '"') {
        for ($j++; $j < $n; $j++) {
          my $e = substr($s, $j, 1);
          if ($e eq '\\') { $j++; next }
          last if $e eq '"';
        }
        return undef if $j >= $n;
        next;
      }
      $depth++ if $d eq $open;
      if ($d eq $close) { $depth--; return $j + 1 if $depth == 0 }
    }
    return undef;
  }
  return $i + 1 + length($1) if substr($s, $i + 1) =~ /\A([A-Za-z_][A-Za-z0-9_]*|[0-9@*#?\$!-])/;
  return undef;
}

# Split the shell word at the start of $s into literal and dynamic segments
# with shell quoting removed. Returns (\@segments) or (undef, reason).
sub shell_word {
  my ($s) = @_;
  my (@seg, $i);
  my $n = length $s;
  my $lit = sub {
    if (@seg && $seg[-1][0] eq 'lit') { $seg[-1][1] .= $_[0] } else { push @seg, ['lit', $_[0]] }
  };
  for ($i = 0; $i < $n;) {
    my $c = substr($s, $i, 1);
    last if $c =~ /[\s;&|<>()]/;
    if ($c eq "'") {
      my $j = index($s, "'", $i + 1);
      return (undef, 'unterminated quote') if $j < 0;
      $lit->(substr($s, $i + 1, $j - $i - 1));
      $i = $j + 1;
    } elsif ($c eq '"') {
      for ($i++; ; ) {
        return (undef, 'unterminated quote') if $i >= $n;
        my $d = substr($s, $i, 1);
        if ($d eq '"') { $i++; last }
        if ($d eq '\\' && substr($s, $i + 1, 1) =~ /[\$`"\\]/) { $lit->(substr($s, $i + 1, 1)); $i += 2; next }
        if ($d eq '$' || $d eq '`') {
          my $j = expansion_end($s, $i);
          return (undef, 'an expansion it cannot delimit') unless defined $j;
          push @seg, ['dyn'];
          $i = $j;
          next;
        }
        $lit->($d);
        $i++;
      }
    } elsif ($c eq '\\') {
      return (undef, 'a trailing backslash') if $i + 1 >= $n;
      $lit->(substr($s, $i + 1, 1));
      $i += 2;
    } elsif ($c eq '$' || $c eq '`') {
      return (undef, 'ANSI-C or locale quoting') if $c eq '$' && substr($s, $i + 1, 1) =~ /['"]/;
      my $j = expansion_end($s, $i);
      return (undef, 'an expansion it cannot delimit') unless defined $j;
      push @seg, ['dyn'];
      $i = $j;
    } elsif ($c =~ /[*?\[]/) {
      push @seg, ['dyn'];
      $i++;
    } else {
      $lit->($c);
      $i++;
    }
  }
  return (\@seg, '', $i);
}

# The file a source command names, following ShellCheck 0.11.0's readSource:
# the first argument (after `--`, or after `-p` and its value) read as a
# literal string, or a literal /tail after one leading expansion (read as
# ./tail); a `~/` path or any other word is never followed (SC1090), so it
# reads no file. A word the tokenizer cannot delimit is unresolvable.
# Returns ('none'), ('path', p), ('tail', t), or ('unresolvable', reason).
sub source_word {
  my ($s) = @_;
  my ($seg, $why, $end) = shell_word($s);
  return ('unresolvable', $why) unless defined $seg;
  if (@$seg == 1 && $seg->[0][0] eq 'lit' && $seg->[0][1] =~ /\A(?:--|-p)\z/) {
    my $skip = $seg->[0][1] eq '-p' ? 2 : 1;
    my $rest = substr($s, $end);
    for (1 .. $skip) {
      $rest =~ s/\A[ \t]+//;
      ($seg, $why, $end) = shell_word($rest);
      return ('unresolvable', $why) unless defined $seg;
      $rest = substr($rest, $end);
    }
  }
  return ('none') unless @$seg;
  if (@$seg == 1 && $seg->[0][0] eq 'lit') {
    my $path = $seg->[0][1];
    return ('none') if $path eq '' || index($path, '~/') == 0;
    return ('path', $path);
  }
  if (@$seg == 2 && $seg->[0][0] eq 'dyn' && $seg->[1][0] eq 'lit' && $seg->[1][1] =~ m{\A/+(.+)\z}s) {
    return ('tail', $1);
  }
  return ('none');
}

sub directive_values {
  my ($line, $key) = @_;
  my @values;
  while ($line =~ /(?:\A|[\s#])\Q$key\E=(?:"([^"]*)"|'([^']*)'|(\S+))/g) {
    push @values, defined $1 ? $1 : defined $2 ? $2 : $3;
  }
  return @values;
}

# Every source reference in one file: [type, value] pairs, source-path
# values, and the first reason the file defeats the scanner (or '').
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
  my ($pending, $problem, $offset) = (0, '', 0);
  for my $line (split /\n/, $text, -1) {
    my $start = $offset;
    $offset += length($line) + 1;
    my $directive = $line =~ /#.*\bshellcheck\b/;
    if ($directive) {
      push @sources, map { ['directive', $_] } directive_values($line, 'source');
      push @paths, directive_values($line, 'source-path');
    }
    if ($line =~ /\A\s*#/) {
      $pending = 1 if $directive && $line =~ /\bsource=/;
      next;
    }
    if ($line !~ /\S/) { $pending = 0; next }
    my $excused = $pending || ($directive && $line =~ /\bsource=/);
    $pending = 0;
    while ($line =~ /(?:\A|[\s;&|(){}!`])(?:source|\.)[ \t]+/g) {
      my ($kind, $value) = source_word(substr($text, $start + pos($line)));
      if ($kind eq 'path' || $kind eq 'tail') { push @sources, ['command', $value, $kind] }
      elsif ($kind eq 'unresolvable' && !$excused && $problem eq '') {
        my $number = (substr($text, 0, $start) =~ tr/\n//) + 1;
        $problem = "$path near line $number has a source argument with $value";
      }
    }
  }
  return $refs{$path} = [\@sources, \@paths, $problem];
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
# A closure file's real path, relative to the working directory when it lies
# below it. The walk parses each real file once, so `..` spellings cannot grow
# it, while the key records every lexical candidate with its real target.
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
  return (undef, 'a -P/--source-path flag is not modeled') if grep { /\A(?:-P|--source-path)/ } @flags;
  return (undef, 'root is not a readable regular file') unless path_kind($root) eq 'file' && defined file_sha($root);
  my $root_real = canonical($root);
  return (undef, 'root has no real path') unless defined $root_real;
  my $root_dir = dirname($root);
  my (%bases, %material, %seen);
  while (1) {
    my $known = scalar keys %bases;
    %material = ("file\0$root\0$root_real\0" . file_sha($root) => 1);
    %seen = ($root_real => 1);
    my @queue = ($root_real);
    while (@queue) {
      my $file = shift @queue;
      my $refs = file_refs($file);
      return (undef, "cannot read $file") unless defined $refs;
      return (undef, $refs->[2]) if length $refs->[2];
      my $file_dir = dirname($file);
      for my $value (@{$refs->[1]}) {
        for my $base (with_scriptdir($value, $root_dir, $file_dir)) {
          $bases{$base} = 1;
          $bases{join_path($file_dir, $base)} = 1 unless $base =~ m{\A/};
        }
      }
      my @dirs = ('.', $root_dir, $file_dir, sort keys %bases);
      for my $ref (@{$refs->[0]}) {
        my ($type, $value, $form) = @$ref;
        my @candidates;
        for my $v (with_scriptdir($value, $root_dir, $file_dir)) {
          (my $rel = $v) =~ s{\A/+}{};
          push @candidates, map { join_path($_, $rel) } @dirs;
          push @candidates, $v if $rel ne $v && ($form // '') ne 'tail';
        }
        for my $candidate (@candidates) {
          my $k = path_kind($candidate);
          if ($k eq 'file') {
            my $real = canonical($candidate);
            my $sha = defined $real ? file_sha($real) : undef;
            return (undef, "cannot read $candidate") unless defined $sha;
            $material{"file\0$candidate\0$real\0$sha"} = 1;
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
  $d->add("fm-lint-cache-key-v2\n", "context\0$context_hash\n", "root\0$root\n", "flags\0" . join("\0", @flags) . "\n");
  $d->add("$_\n") for sort keys %material;
  return ($d->hexdigest, '');
}

sub entry_text {
  my ($key, $root, $reason) = @_;
  my $body = "fm-lint-cache-entry-v1\nkey $key\nverdict pass\nreason $reason\nroot $root\n";
  return $body . 'check ' . sha256_hex($body) . "\n";
}

# Returns ('none'), ('pass', reason), or ('corrupt', detail). Only a readable
# regular file is an entry: a symlink, FIFO, or other node is corrupt, checked
# on the path and on the descriptor opened without blocking.
sub read_entry {
  my ($key, $root) = @_;
  if (lstat $entries) {
    return ('corrupt', "cache entries path $entries is not a directory") unless -d _;
  } elsif (!$!{ENOENT}) {
    return ('corrupt', "cannot inspect cache entries path $entries: $!");
  }
  my $path = "$entries/$key";
  unless (lstat $path) {
    return ('none') if $!{ENOENT};
    return ('corrupt', "unreadable entry $path: $!");
  }
  return ('corrupt', "entry $path is not a regular file") unless -f _;
  sysopen(my $fh, $path, O_RDONLY | O_NONBLOCK) or return ('corrupt', "unreadable entry $path: $!");
  unless (-f $fh) { close $fh; return ('corrupt', "entry $path is not a regular file") }
  binmode $fh;
  my $text = '';
  my $n = sysread($fh, $text, 8192);
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
    env -u SHELLCHECK_OPTS "$bin" --version 2>&1 | sed 's/^/shellcheck-version /'
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
  fm_lint_cache_helper prune "$FM_LINT_CACHE_DIR" 14 2>/dev/null || true
}

# Print the run's hit and miss counts and, beside --telemetry, write the
# per-root cache sidecar a later audit compares against.
fm_lint_cache_report() {  # <sidecar-path-or-empty>
  local sidecar=$1 index hits=0 misses stored=0 uncacheable=0 status
  for ((index = 1; index <= ROOT_COUNT; index++)); do
    status=${FM_LINT_CACHE_STATUS[index]:-}
    [ -z "${FM_LINT_CACHE_HIT[index]:-}" ] || hits=$((hits + 1))
    [ "$status" != stored ] || stored=$((stored + 1))
    [ "$status" != uncacheable ] || uncacheable=$((uncacheable + 1))
  done
  misses=$((ROOT_COUNT - hits))
  # shellcheck disable=SC2034 # fm-lint.sh writes these into its telemetry.
  FM_LINT_CACHE_HITS=$hits FM_LINT_CACHE_MISSES=$misses FM_LINT_CACHE_STORED=$stored
  printf 'fm-lint.sh: lint cache: hits=%s misses=%s stored=%s uncacheable=%s scope=%s state=%s\n' \
    "$hits" "$misses" "$stored" "$uncacheable" "$(fm_lint_cache_scope)" "$FM_LINT_CACHE_STATE" >&2
  [ -n "$sidecar" ] || return 0
  {
    printf 'format\tfm-lint-cache-v1\n'
    printf 'meta\tstate\t%s\n' "$FM_LINT_CACHE_STATE"
    printf 'meta\tscope\t%s\n' "$(fm_lint_cache_scope)"
    printf 'meta\tgit_head\t%s\n' "$(fm_lint_cache_head)"
    printf 'meta\tpartition\t%s\n' "${PARTITION:-all}"
    for ((index = 1; index <= ROOT_COUNT; index++)); do
      status=${FM_LINT_CACHE_STATUS[index]:-linted}
      [ "$status" != hit ] || [ -n "${FM_LINT_CACHE_HIT[index]:-}" ] || status=relinted
      printf 'root\t%s\t%s\t%s\n' "${ROOTS[index - 1]}" "$status" "${FM_LINT_CACHE_KEY[index]:--}"
    done
    printf 'meta\troot_count\t%s\n' "$ROOT_COUNT"
    printf 'meta\thits\t%s\n' "$hits"
    printf 'meta\tmisses\t%s\n' "$misses"
    printf 'meta\tstored\t%s\n' "$stored"
    printf 'meta\tuncacheable\t%s\n' "$uncacheable"
  } > "$sidecar" || fm_lint_cache_warn "could not write the cache sidecar $sidecar"
}

fm_lint_cache_head() {
  git rev-parse HEAD 2>/dev/null || printf 'unavailable\n'
}

fm_lint_cache_stale() {  # <key> <root> <source>
  local message="STALE LINT CACHE KEY $1: $2 has findings in this uncached run, but $3 recorded a pass for that key"
  printf 'fm-lint.sh: %s\n' "$message" >&2
  [ "${GITHUB_ACTIONS:-}" != true ] || printf '::error title=Stale lint cache key::%s\n' "$message"
}

# The uncached audit: compare every root with findings in this run against the
# recorded passes of AUDIT_CACHE and of each AUDIT_RECORDS sidecar for this
# commit. Sets FM_LINT_CACHE_STALE to the number of stale keys proven. A root
# with findings that no same-commit sidecar covers and the cache does not
# record is an incomplete audit: reported loudly, with its recomputed key named
# as an unproven candidate, never as the key a cached run replayed.
fm_lint_cache_audit() {
  local kind index path shard reason flags record rpath rstatus rkey status key detail head record_head
  local -A failing=() covered=() candidate=()
  FM_LINT_CACHE_STALE=0
  [ -n "$AUDIT_CACHE" ] || [ "${#AUDIT_RECORDS[@]}" -gt 0 ] || return 0
  head=$(fm_lint_cache_head)
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
  [ "${#failing[@]}" -gt 0 ] || return 0
  fm_lint_cache_write_context "$TMP_ROOT/cache.context" "$SHELLCHECK_BIN" "$(fm_lint_cache_scope)" \
    "${FM_LINT_DEFINITION_FILES[@]}"
  if [ -s "$TMP_ROOT/cache.audit" ] \
    && fm_lint_cache_helper audit "${AUDIT_CACHE:-$TMP_ROOT/no-audit-cache}" "$TMP_ROOT/cache.context" \
      < "$TMP_ROOT/cache.audit" > "$TMP_ROOT/cache.audited" 2> "$TMP_ROOT/cache.audited.err"; then
    while IFS=$'\t' read -r index status key detail; do
      path=${ROOTS[index - 1]}
      candidate[$path]=$key
      case "$status" in
        pass-recorded)
          [ -n "$AUDIT_CACHE" ] || continue
          fm_lint_cache_stale "$key" "$path" "the cache at $AUDIT_CACHE"
          FM_LINT_CACHE_STALE=$((FM_LINT_CACHE_STALE + 1))
          covered[$path]=1
          ;;
        corrupt) fm_lint_cache_warn "audit found $detail" ;;
      esac
    done < "$TMP_ROOT/cache.audited"
  elif [ -s "$TMP_ROOT/cache.audit" ]; then
    fm_lint_cache_warn "could not recompute the audited keys ($(head -n1 "$TMP_ROOT/cache.audited.err"))"
  fi
  for record in "${AUDIT_RECORDS[@]}"; do
    if [ ! -r "$record" ]; then
      fm_lint_cache_warn "cannot read the cached run's sidecar $record"
      continue
    fi
    record_head=$(awk -F '\t' '$1 == "meta" && $2 == "git_head" { print $3; exit }' "$record")
    if [ "$record_head" != "$head" ]; then
      fm_lint_cache_warn "ignoring the sidecar $record: it records commit ${record_head:-unknown}, not $head"
      continue
    fi
    while IFS=$'\t' read -r kind rpath rstatus rkey; do
      [ "$kind" = root ] && [ -n "${failing[$rpath]:-}" ] || continue
      covered[$rpath]=1
      case "$rstatus" in hit|stored) ;; *) continue ;; esac
      fm_lint_cache_stale "$rkey" "$rpath" "the cached run's sidecar $record"
      FM_LINT_CACHE_STALE=$((FM_LINT_CACHE_STALE + 1))
    done < "$record"
  done
  for path in "${!failing[@]}"; do
    [ -z "${covered[$path]:-}" ] || continue
    detail="AUDIT INCOMPLETE: $path has findings at commit $head (partition ${PARTITION:-all}), but neither a same-commit cached run's sidecar nor the restored cache proves which key a cached run replayed; the recomputed candidate key ${candidate[$path]:-unavailable} is unproven"
    printf 'fm-lint.sh: %s\n' "$detail" >&2
    [ "${GITHUB_ACTIONS:-}" != true ] || printf '::error title=Lint cache audit incomplete::%s\n' "$detail"
  done
}
