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

# searchOnExpr() on a value containing a quote
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

done_testing();

END {
    unlink $dbfile if ( $dbfile and -e $dbfile );
}
