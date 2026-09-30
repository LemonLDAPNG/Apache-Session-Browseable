use strict;
use warnings;
use utf8;
use Test::More;

my $class = 'Apache::Session::Browseable::Redis';

plan skip_all => 'Set REDIS_URL to run Redis tests' unless $ENV{REDIS_URL};
plan skip_all => 'Redis module is needed' unless eval "require $class";

# Not the databases of the other Redis tests, to run them in parallel
my $args = {
    server   => $ENV{REDIS_URL},
    database => ( ( $ENV{REDIS_DBNUM} || 15 ) + 14 ) % 16,
    Index    => 'uid cn u?x',
};
my $redis = $class->_getRedis($args);
$redis->flushdb;

my %ids;
foreach my $u (
    [ 'CORP\jdoe',  'John' ],
    [ 'CORP\jsmith', 'Jane' ],
    [ 'CORP\other', 'Other' ],
    [ 'CORPxjdoe',  'X' ],
    [ 'a?c',        'Q' ],
    [ 'abc',        'B' ],
    [ 'a[b]',       'Br' ],
    [ 'élodie',     'Élodie' ],
  )
{
    my %session;
    tie %session, $class, undef, $args;
    $session{uid}   = $u->[0];
    $session{cn}    = $u->[1];
    $session{'u?x'} = $u->[0];
    $ids{ $session{_session_id} } = $u->[0];
    untie %session;
}
my $names = sub { [ sort map { $ids{$_} } keys %{ $_[0] } ] };

is_deeply(
    $names->( $class->searchOnExpr( $args, 'uid', 'CORP\jd*' ) ),
    ['CORP\jdoe'],
    'backslash in value'
);
is_deeply(
    $names->( $class->searchOnExpr( $args, 'uid', 'CORP\*' ) ),
    [ 'CORP\jdoe', 'CORP\jsmith', 'CORP\other' ],
    'backslash before wildcard'
);
is_deeply( $names->( $class->searchOnExpr( $args, 'uid', 'a?c' ) ),
    ['a?c'], '? is not a wildcard' );
is_deeply( $names->( $class->searchOnExpr( $args, 'uid', 'a[b]' ) ),
    ['a[b]'], 'brackets are literal' );
is_deeply( $names->( $class->searchOnExpr( $args, 'u?x', 'a*' ) ),
    [ 'a?c', 'a[b]', 'abc' ], 'field name with ?' );
is_deeply( $names->( $class->searchOn( $args, 'uid', 'CORP\jdoe' ) ),
    ['CORP\jdoe'], 'searchOn with backslash' );
is_deeply( $names->( $class->searchOn( $args, 'uid', 'élodie' ) ),
    ['élodie'], 'searchOn with non-ASCII value' );
is_deeply( $names->( $class->searchOnExpr( $args, 'uid', 'él*' ) ),
    ['élodie'], 'searchOnExpr with non-ASCII value' );
my ($id) = keys %{ $class->searchOn( $args, 'cn', 'Élodie' ) };
is( $ids{$id}, 'élodie', 'searchOn with non-ASCII index name' );

# Several SCAN pages and MGET batches
{
    no warnings 'once';
    local $Apache::Session::Browseable::Redis::SCAN_COUNT = 2;
    local $Apache::Session::Browseable::Redis::MGET_BATCH = 3;
    my %all;
    foreach my $i ( 1 .. 30 ) {
        my %session;
        tie %session, $class, undef, $args;
        $session{uid} = "page$i";
        $session{cn}  = 'sameCn';
        $all{ $session{_session_id} } = "page$i";
        untie %session;
    }
    is( scalar keys %{ $class->searchOnExpr( $args, 'uid', 'page*' ) },
        30, 'SCAN over several pages' );
    is( scalar keys %{ $class->searchOn( $args, 'cn', 'sameCn' ) },
        30, 'MGET in several batches' );
    is( scalar keys %{ $class->searchOnExpr( $args, 'cn', 'same*' ) },
        30, 'SCAN + MGET batches' );
}

$redis->flushdb;
done_testing();
