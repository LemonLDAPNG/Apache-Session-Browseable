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

# Like quiet(), but also returns what was written to STDERR
sub quiet_err(&) {
    my ($code) = @_;
    local *STDERR;
    my $err = '';
    open STDERR, '>', \$err;
    my $res = $code->();
    return ( $res, $err );
}

my ( $ids, $res, @res, $rule, $ret, $err );

# deleteIfLowerThan with "or"
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

# deleteIfLowerThan with "and"
$ids = reset_sessions(
    a => { _utime => 100, _lastSeen => 100 },
    b => { _utime => 100, _lastSeen => 300 },
    c => { _utime => 300, _lastSeen => 100 },
);
@res = $class->deleteIfLowerThan( $args,
    { and => { _utime => 250, _lastSeen => 250 } } );
is_deeply( \@res, [ 1, 1 ], 'and: 1 session deleted' );
is( remaining($ids), 'b,c', 'and: sessions "b" and "c" remain' );

# deleteIfLowerThan with "not"
$ids = reset_sessions(
    sso     => { _utime => 100, _session_kind => 'SSO' },
    persist => { _utime => 100, _session_kind => 'Persistent' },
    nokind  => { _utime => 100 },
    recent  => { _utime => 300, _session_kind => 'SSO' },
);
$rule =
  { or => { _utime => 250 }, not => { _session_kind => 'Persistent' } };
@res = $class->deleteIfLowerThan( $args, $rule );
is_deeply( \@res, [ 1, 2 ], 'not: 2 sessions deleted' );
is( remaining($ids), 'persist,recent',
    'not: session without _session_kind deleted' );

done_testing();

END {
    unlink $dbfile if ( $dbfile and -e $dbfile );
}
