# SQL correctness tests of Apache::Session::Browseable::DBI using SQLite

use strict;
use warnings;
use Test::More;
use File::Temp qw(mktemp);

my $dbfile = mktemp('tmp.db_XXXX');

plan skip_all => "DBD::SQLite is needed for this test"
  unless eval {
    require DBI;
    require DBD::SQLite;
    1;
  };

my $dbh = DBI->connect( "dbi:SQLite:dbname=$dbfile", "", "",
    { RaiseError => 1, PrintError => 0 } );
$dbh->do( 'CREATE TABLE sessions(id char(64) not null primary key,'
      . 'a_session text,_utime text,_lastSeen text,_session_kind text,uid text)'
);

my $class = 'Apache::Session::Browseable::SQLite';
use_ok($class);

my $args = {
    DataSource => "dbi:SQLite:$dbfile",
    Index      => '_utime _lastSeen _session_kind uid',
};

sub newSession {
    my %data = @_;
    my %session;
    tie %session, $class, undef, $args;
    $session{$_} = $data{$_} foreach ( keys %data );
    my $id = $session{_session_id};
    untie %session;
    return $id;
}

sub reset_sessions {
    $dbh->do('DELETE FROM sessions');
    my %ids;
    while (@_) {
        my ( $name, $data ) = splice @_, 0, 2;
        $ids{$name} = newSession(%$data);
    }
    return \%ids;
}

sub remaining {
    my ($ids) = @_;
    my $all = $class->get_key_from_all_sessions($args);
    my %rev = reverse %$ids;
    return join ',', sort map { $rev{$_} } keys %$all;
}

sub quiet(&) {
    my ($code) = @_;
    local *STDERR;
    my $err = '';
    open STDERR, '>', \$err;
    return $code->();
}

my ( $ids, $res, @res );

# 1. deleteIfLowerThan with "or"
$ids = reset_sessions(
    a => { _utime => 100, _lastSeen => 400 },
    b => { _utime => 200, _lastSeen => 400 },
    c => { _utime => 300, _lastSeen => 400 },
);
@res = $class->deleteIfLowerThan( $args, { or => { _utime => 250 } } );
is_deeply( \@res, [ 1, 2 ], 'or: 2 sessions deleted' );
is( remaining($ids), 'c', 'or: session "c" remains' );

$ids = reset_sessions(
    a => { _utime => 100, _lastSeen => 400 },
    b => { _utime => 400, _lastSeen => 100 },
    c => { _utime => 400, _lastSeen => 400 },
);
ok(
    $class->deleteIfLowerThan(
        $args, { or => { _utime => 250, _lastSeen => 250 } }
    ),
    'or with 2 fields'
);
is( remaining($ids), 'c', 'or: session "c" remains' );

# 2. deleteIfLowerThan with "and"
$ids = reset_sessions(
    a => { _utime => 100, _lastSeen => 100 },
    b => { _utime => 100, _lastSeen => 300 },
    c => { _utime => 300, _lastSeen => 100 },
);
@res = $class->deleteIfLowerThan( $args,
    { and => { _utime => 250, _lastSeen => 250 } } );
is_deeply( \@res, [ 1, 1 ], 'and: 1 session deleted' );
is( remaining($ids), 'b,c', 'and: sessions "b" and "c" remain' );

# 3. deleteIfLowerThan with "not"
$ids = reset_sessions(
    sso     => { _utime => 100, _session_kind => 'SSO' },
    persist => { _utime => 100, _session_kind => 'Persistent' },
    nokind  => { _utime => 100 },
    recent  => { _utime => 300, _session_kind => 'SSO' },
);
my $rule =
  { or => { _utime => 250 }, not => { _session_kind => 'Persistent' } };
@res = $class->deleteIfLowerThan( $args, $rule );
is_deeply( \@res, [ 1, 2 ], 'not: 2 sessions deleted' );
is( remaining($ids), 'persist,recent',
    'not: session without _session_kind deleted' );

# 4. "not" value containing a quote is bound, not interpolated
$ids = reset_sessions(
    obrien => { _utime => 100, _session_kind => "O'Brien" },
    other  => { _utime => 100, _session_kind => 'x' },
    recent => { _utime => 300, _session_kind => 'x' },
);
$rule = { or => { _utime => 250 }, not => { _session_kind => "O'Brien" } };
ok( $class->deleteIfLowerThan( $args, $rule ), 'not with quote' );
is( remaining($ids), 'obrien,recent', 'not with quote: "other" deleted' );
is( $rule->{not}->{_session_kind}, "O'Brien", 'rule is not modified' );

$ids = reset_sessions(
    a      => { _utime => 100, _session_kind => 'a' },
    recent => { _utime => 300, _session_kind => 'x' },
);
ok(
    $class->deleteIfLowerThan(
        $args,
        { or => { _utime => 250 }, not => { _session_kind => "x' OR '1'='1" } }
    ),
    'not with injection attempt'
);
is( remaining($ids), 'recent', 'not with injection attempt: no injection' );

# 5. deleteIfLowerThan with only "not" does nothing
$ids = reset_sessions(
    a => { _utime => 100, _session_kind => 'SSO' },
    b => { _utime => 100, _session_kind => 'Persistent' },
);
is(
    eval {
        $class->deleteIfLowerThan( $args,
            { not => { _session_kind => 'Persistent' } } );
    },
    0,
    'only not: returns 0'
) or diag $@;
is( remaining($ids), 'a,b', 'only not: nothing deleted' );

# 6. deleteIfLowerThan with a non numeric threshold does nothing
foreach my $bad ( '100 OR 1=1', '1e3', '', undef ) {
    is(
        quiet {
            eval {
                $class->deleteIfLowerThan( $args,
                    { or => { _utime => $bad } } );
            }
        },
        0,
        'non numeric threshold: returns 0 ('
          . ( defined $bad ? "'$bad'" : 'undef' ) . ')'
    );
}
is(
    quiet {
        $class->deleteIfLowerThan( $args,
            { and => { _utime => 250, _lastSeen => 'x' } } );
    },
    0,
    'non numeric "and" threshold: returns 0'
);
is(
    quiet {
        $class->deleteIfLowerThan( $args,
            { or => { _utime => "\x{0661}\x{0662}" } } );
    },
    0,
    'non ASCII digits threshold: returns 0'
);
foreach my $bad ( 'a', [ _utime => 250 ], \'x' ) {
    foreach my $type (qw(or and)) {
        is(
            quiet {
                eval { $class->deleteIfLowerThan( $args, { $type => $bad } ) };
            },
            0,
            "\"$type\" is not a hash ref ("
              . ( ref($bad) || $bad )
              . '): returns 0'
        ) or diag $@;
    }
}
is( remaining($ids), 'a,b', 'non numeric threshold: nothing deleted' );

# 7. deleteIfLowerThan with a decimal or negative threshold
ok( $class->deleteIfLowerThan( $args, { or => { _utime => '100.5' } } ),
    'decimal threshold accepted' );
ok( $class->deleteIfLowerThan( $args, { or => { _utime => '-1' } } ),
    'negative threshold accepted' );

# 8. searchOnExpr() on a value containing a quote
$ids = reset_sessions(
    obrien  => { uid => "O'Brien",  f3 => "O'Brien" },
    obriena => { uid => "O'Briena", f3 => "O'Briena" },
    other   => { uid => 'OBrien',   f3 => 'OBrien' },
);
my %rev = reverse %$ids;
$res = $class->searchOnExpr( $args, 'uid', "O'Brien*" );
is( join( ',', sort map { $rev{$_} } keys %$res ),
    'obrien,obriena', 'searchOnExpr with a quote on an indexed field' );
$res = $class->searchOnExpr( $args, 'uid', "O'Brien*", 'uid' );
is( join( ',', sort map { $res->{$_}->{uid} } keys %$res ),
    "O'Brien,O'Briena",
    'searchOnExpr with a quote on an indexed field, with fields' );
$res = $class->searchOnExpr( $args, 'f3', "O'Brien*" );
is( join( ',', sort map { $rev{$_} } keys %$res ),
    'obrien,obriena', 'searchOnExpr with a quote on an unindexed field' );
$res = $class->searchOn( $args, 'uid', "O'Brien" );
is( join( ',', keys %$res ),
    $ids->{obrien}, 'searchOn with a quote on an indexed field' );

# 9. Caller data must not be modified
my $fields = [ 'uid', '_utime' ];
$res = $class->get_key_from_all_sessions( $args, $fields );
is( $res->{ $ids->{obrien} }->{uid},
    "O'Brien", 'get_key_from_all_sessions with indexed fields' );
is_deeply( $fields, [ 'uid', '_utime' ], 'Fields list not modified' );

my $qargs = { %$args, Index => [ 'uid', "a'b" ] };
$fields = [ 'uid', "a'b" ];
quiet {
    eval { $class->get_key_from_all_sessions( $qargs, $fields ) }
};
is_deeply(
    $fields,
    [ 'uid', "a'b" ],
    'Fields list not modified (field containing a quote)'
);

require Apache::Session::Browseable::Store::SQLite;
my $store = Apache::Session::Browseable::Store::SQLite->new;
quiet {
    eval {
        $store->insert(
            {
                args       => $qargs,
                data       => { _session_id => 'x' },
                serialized => '{}'
            }
        );
    }
};
is_deeply( $qargs->{Index}, [ 'uid', "a'b" ], 'Store: Index not modified' );

done_testing();

END {
    unlink $dbfile if ( $dbfile and -e $dbfile );
}
