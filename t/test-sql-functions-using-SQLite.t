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

# deleteIfLowerThan with only "not" does nothing
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

# "or" / "and" that are not hash refs
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
is( remaining($ids), 'a,b', 'invalid "or"/"and": nothing deleted' );

# empty or invalid "not" in the rule
$ids = reset_sessions(
    old => { _utime => 100, _session_kind => 'SSO' },
    new => { _utime => 300, _session_kind => 'SSO' },
);
( $ret, $err ) = quiet_err {
    eval {
        $class->deleteIfLowerThan( $args,
            { or => { _utime => 200 }, not => {} } );
    };
};
is( $ret, 1, 'empty not: returns 1' ) or diag $@;
is( $err, '', 'empty not: no warning' );
is( remaining($ids), 'new', 'empty not: clause ignored' );

foreach my $bad ( 'x', [ _session_kind => 'y' ], \'x' ) {
    ( $ret, $err ) = quiet_err {
        eval {
            $class->deleteIfLowerThan( $args,
                { or => { _utime => 200 }, not => $bad } );
        };
    };
    is( $ret, 0,
        '"not" is not a hash ref (' . ( ref($bad) || $bad ) . '): returns 0' )
      or diag $@;
    like( $err, qr/not must be a hash reference/,
        '"not" is not a hash ref (' . ( ref($bad) || $bad ) . '): warning' );
}
foreach my $bad ( 'x', [ _utime => 200 ], \'x', undef ) {
    ( $ret, $err ) =
      quiet_err { eval { $class->deleteIfLowerThan( $args, $bad ) } };
    is( $ret, 0,
        'rule is not a hash ref ('
          . ( ref($bad) || ( defined $bad ? $bad : 'undef' ) )
          . '): returns 0' )
      or diag $@;
    like( $err, qr/rule must be a hash reference/,
        'rule is not a hash ref ('
          . ( ref($bad) || ( defined $bad ? $bad : 'undef' ) )
          . '): warning' );
}
is( remaining($ids), 'new', 'invalid rule: nothing deleted' );

# SQL failure (missing table): no die, false / (0, 0) and a message
my $badArgs = { %$args, TableName => 'no_such_table' };
$rule = { or => { _utime => 250 } };
( $ret, $err ) = quiet_err {
    my @r = eval { $class->deleteIfLowerThan( $badArgs, $rule ) };
    $@ ? 'died' : join( ',', @r );
};
is( $ret, '0,0', 'SQL failure: returns (0, 0) in list context' ) or diag $@;
like( $err, qr/deleteIfLowerThan: /, 'SQL failure: message on STDERR' );
( $ret, $err ) = quiet_err {
    my $r = eval { $class->deleteIfLowerThan( $badArgs, $rule ) };
    $@ ? 'died' : ( $r ? 'true' : 'false' );
};
is( $ret, 'false', 'SQL failure: returns false in scalar context' );
like( $err, qr/deleteIfLowerThan: /, 'SQL failure: message on STDERR' );

done_testing();

END {
    unlink $dbfile if ( $dbfile and -e $dbfile );
}
