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

done_testing();
