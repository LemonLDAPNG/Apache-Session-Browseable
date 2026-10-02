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

# Caller data must not be modified
$ids = reset_sessions( obrien => { uid => "O'Brien", _utime => 100 } );
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
