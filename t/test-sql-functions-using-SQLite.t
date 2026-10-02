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

# "not" value containing a quote is bound, not interpolated
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

# deleteIfLowerThan with a non numeric threshold does nothing
$ids = reset_sessions(
    a => { _utime => 100, _session_kind => 'SSO' },
    b => { _utime => 100, _session_kind => 'Persistent' },
);
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
is( remaining($ids), 'a,b', 'non numeric threshold: nothing deleted' );

# deleteIfLowerThan with a decimal or negative threshold
ok( $class->deleteIfLowerThan( $args, { or => { _utime => '100.5' } } ),
    'decimal threshold accepted' );
ok( $class->deleteIfLowerThan( $args, { or => { _utime => '-1' } } ),
    'negative threshold accepted' );

done_testing();

END {
    unlink $dbfile if ( $dbfile and -e $dbfile );
}
