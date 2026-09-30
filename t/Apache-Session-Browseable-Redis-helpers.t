use strict;
use warnings;
use Test::More;

my $class = 'Apache::Session::Browseable::Redis';

plan skip_all => 'Redis module is needed' unless eval "require $class";

# SCAN patterns: '*' is the only wildcard of the value
is( $class->can('_exprPattern')->( 'uid', 'jdoe' ),  'uid_jdoe',  'plain' );
is( $class->can('_exprPattern')->( 'uid', 'jd*' ),   'uid_jd*',   'wildcard' );
is( $class->can('_exprPattern')->( 'uid', 'CORP\\jd*' ),
    'uid_CORP\\\\jd*', 'backslash in value' );
is( $class->can('_exprPattern')->( 'uid', 'a?[b]' ),
    'uid_a\\?\\[b\\]', 'glob chars in value' );
is( $class->can('_exprPattern')->( 'u?[*]\\d', 'x' ),
    'u\\?\\[\\*\\]\\\\d_x', 'glob chars in field name' );
is( $class->can('_globEscape')->('a*b'), 'a\\*b', '_globEscape' );

# Key names: Latin-1 bytes when possible (existing sets), else UTF-8 bytes
my $keyName = $class->can('_keyName');
is( $keyName->('uid_dwho'), 'uid_dwho', 'keyName: ASCII' );
is( $keyName->("uid_m\x{e9}"), "uid_m\xe9", 'keyName: Latin-1' );
ok( !utf8::is_utf8( $keyName->("uid_m\x{e9}") ), 'keyName: Latin-1 bytes' );
is( $keyName->("uid_\x{3a9}"), "uid_\xce\xa9", 'keyName: UTF-8' );
is( $keyName->("\x{e9}_\x{20ac}"), "\xc3\xa9_\xe2\x82\xac",
    'keyName: whole name in UTF-8' );
is( $keyName->("uid_\x{1f600}"), "uid_\xf0\x9f\x98\x80", 'keyName: emoji' );
is( $keyName->(42), '42', 'keyName: number' );
{
    my $s = "uid_\x{3a9}";
    $keyName->($s);
    is( $s, "uid_\x{3a9}", 'keyName: argument unchanged' );
}
is( $class->can('_exprPattern')->( 'uid', "\x{3a9}*" ),
    "uid_\xce\xa9*", 'pattern with wide characters' );
is_deeply(
    [ $class->can('_exprPatterns')->( 'uid', "m\x{e9}*" ) ],
    ["uid_m\xe9*", "uid_m\xc3\xa9*"],
    'patterns: Latin-1 and UTF-8'
);
is_deeply( [ $class->can('_exprPatterns')->( 'uid', 'jd*' ) ],
    ['uid_jd*'], 'patterns: ASCII' );
is_deeply( [ $class->can('_exprPatterns')->( 'uid', "m\x{e9}" ) ],
    ["uid_m\xe9"], 'patterns: no wildcard' );

# Orphan removal without Lua
{

    package FakeRedis;
    our @log;
    our $lua = 0;
    our $exists = 0;
    sub new { bless {}, shift }
    sub eval { die "ERR unknown command 'eval'\n" unless $lua; push @log, 'eval'; 1 }
    sub watch   { push @log, 'watch' }
    sub unwatch { push @log, 'unwatch' }
    sub exists  { push @log, 'exists'; $exists }
    sub multi   { push @log, 'multi' }
    sub srem    { shift; push @log, join ' ', 'srem', @_ }
    sub exec    { push @log, 'exec' }
    sub discard { push @log, 'discard' }
}
{
    my $err = '';
    local *STDERR;
    open STDERR, '>', \$err;
    my $r = FakeRedis->new;
    $class->_removeOrphan( $r, 'uid_x', 'k' );
    is_deeply(
        \@FakeRedis::log,
        [ 'watch', 'exists', 'multi', 'srem uid_x k', 'exec' ],
        'fallback: WATCH/MULTI/EXEC'
    );
    like( $err, qr/^Redis EVAL failed/, 'fallback: error printed' );
    @FakeRedis::log = ();
    $err            = '';
    $FakeRedis::exists = 1;
    $class->_removeOrphan( $r, 'uid_x', 'k' );
    is_deeply( \@FakeRedis::log, [ 'watch', 'exists', 'unwatch' ],
        'fallback: existing session is kept' );
    is( $err, '', 'fallback: error printed once' );
    @FakeRedis::log = ();
    $FakeRedis::lua = 1;
    $class->_removeOrphan( $r, 'uid_x', 'k' );
    is_deeply( \@FakeRedis::log, ['eval'], 'Lua used when available' );
}

# Redis errors: fatal for searchOn/searchOnExpr, ignored by searchLt
{

    package FakeRedis2;
    sub smembers { die "ERR timeout\n" }
    sub scan     { return ( 0, ['uid_1'] ) }
}
{
    no warnings 'redefine';
    local *Apache::Session::Browseable::Redis::_getRedis =
      sub { bless {}, 'FakeRedis2' };
    my $args = { Index => 'uid' };
    ok( !eval { $class->searchOn( $args, 'uid', 'x' ); 1 },
        'searchOn dies on Redis error' );
    like( $@, qr/timeout/, 'searchOn: error message' );
    ok( !eval { $class->searchOnExpr( $args, 'uid', 'x*' ); 1 },
        'searchOnExpr dies on Redis error' );
    my $err = '';
    my $res;
    {
        local *STDERR;
        open STDERR, '>', \$err;
        $res = eval { $class->searchLt( $args, 'uid', 10 ) };
    }
    is_deeply( $res, {}, 'searchLt ignores Redis error' );
}

# Pipelined reads: SMEMBERS of several sets, one MGET
{

    package FakePipe;
    our ( @log, %sets, %vals, $fail );
    sub new { bless { cbs => [] }, shift }
    sub smembers {
        my ( $self, $set, $cb ) = @_;
        push @log, "smembers $set";
        push @{ $self->{cbs} }, sub {
            $fail ? $cb->( undef, $fail ) : exists $sets{$set}
              ? $cb->( $sets{$set} )
              : $cb->( undef, 'WRONGTYPE bad' );
        };
    }
    sub wait_all_responses { $_->() foreach @{ $_[0]->{cbs} }; $_[0]->{cbs} = [] }
    sub mget { shift; push @log, 'mget ' . scalar(@_); map { $vals{$_} } @_ }
    sub eval { push @log, 'eval'; 1 }
}
{
    my ( $a1, $b1 ) = ( 'a' x 32, 'b' x 32 );
    %FakePipe::sets = ( s1 => [ $a1, $b1, 'foreign' ], s2 => [$a1], s4 => [$b1] );
    %FakePipe::vals = (
        $a1 => '{"uid":"x","_session_id":"' . $a1 . '"}',
        $b1 => undef,
    );
    my $r = FakePipe->new;
    my %got;
    $class->_readSets( {}, $r, [qw(s1 s2 s3)], undef, 1,
        sub { $got{ $_[0] } = [ sort keys %{ $_[1] } ] } );
    is_deeply( \%got, { s1 => [$a1], s2 => [$a1], s3 => [] },
        'pipeline: sessions per set' );
    is_deeply(
        [ grep { !/^eval/ } @FakePipe::log ],
        [ 'smembers s1', 'smembers s2', 'smembers s3', 'mget 2' ],
        'pipeline: one MGET for all sets'
    );
    is( scalar( grep { /^eval/ } @FakePipe::log ), 1, 'orphan removed' );
    $FakePipe::fail = 'ERR timeout';
    ok( !eval { $class->_readSets( {}, $r, [qw(s1 s2)], undef, 1, sub { } ); 1 },
        'pipeline: Redis error is fatal if strict' );
    my $err = '';
    {
        local *STDERR;
        open STDERR, '>', \$err;
        $class->_readSets( {}, $r, [qw(s1 s2)], undef, 0, sub { $got{x}++ } );
    }
    like( $err, qr/timeout/, 'pipeline: Redis error reported if not strict' );
    ok( !$got{x}, 'pipeline: sets ignored' );
}

# deleteIfLowerThan decision: only a missing _utime means "expired"
{
    my $dom  = $class->can('_isDominated');
    my $sid  = { _session_id => 'x' };
    my $or   = { or => { _utime => 100, _lastSeen => 100 } };
    my $and  = { and => { _utime => 100, _lastSeen => 100 } };
    ok( $dom->( $class, {}, $or ), 'empty session is dominated' );
    ok( $dom->( $class, undef, $and ), 'undef session is dominated' );
    ok( $dom->( $class, { uid => 'a' }, $or ),
        'session without _session_id is dominated' );
    ok( !$dom->( $class, { %$sid, _utime => 200 }, $or ),
        'or: recent _utime, no _lastSeen: kept' );
    ok( $dom->( $class, { %$sid, _utime => 50 }, $or ),
        'or: old _utime, no _lastSeen: dominated' );
    ok( $dom->( $class, { %$sid, _lastSeen => 50, _utime => 200 }, $or ),
        'or: old _lastSeen: dominated' );
    ok( $dom->( $class, { %$sid, _lastSeen => 200 }, $or ),
        'or: no _utime: dominated' );
    ok( !$dom->( $class, { %$sid, _utime => 200, _lastSeen => 200 }, $or ),
        'or: recent session kept' );
    ok( !$dom->( $class, { %$sid, _utime => 50 }, $and ),
        'and: missing _lastSeen: kept' );
    ok( $dom->( $class, { %$sid, _utime => 50, _lastSeen => 50 }, $and ),
        'and: all lower: dominated' );
    ok( !$dom->( $class, { %$sid, _utime => 50, _lastSeen => 150 }, $and ),
        'and: one not lower: kept' );
    ok( $dom->( $class, { %$sid, _lastSeen => 50 }, $and ),
        'and: missing _utime counts as lower' );
    ok( !$dom->( $class, { %$sid, _utime => 50 }, {} ), 'no rule: kept' );
}

done_testing();
