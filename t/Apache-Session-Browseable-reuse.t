#!/usr/bin/perl

# "reuse" option of DBI stores, tested with SQLite

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Scalar::Util qw(refaddr);

plan skip_all => "DBD::SQLite is needed for this test"
  unless eval {
    require DBI;
    require DBD::SQLite;
    1;
  };

my $dir = tempdir( CLEANUP => 1 );
my $dsn = "dbi:SQLite:dbname=$dir/sessions.db";

# Other connection, used to check that stores leave no transaction open: a
# SQLite transaction that has read the table prevents others from writing
my $other = DBI->connect( $dsn, '', '',
    { RaiseError => 1, PrintError => 0, AutoCommit => 1 } );
$other->do('CREATE TABLE sessions (id char(32) not null primary key,'
      . ' a_session text, uid text)');
$other->sqlite_busy_timeout(100);
my $canWrite = sub {
    eval { $other->do('UPDATE sessions SET uid = uid'); 1 };
};
my $stored = sub {
    $other->selectrow_array( 'SELECT count(*) FROM sessions WHERE id = ?',
        undef, $_[0] );
};
my $quiet = sub {
    local $SIG{__WARN__} = sub { };
    return eval { $_[0]->(); 1 };
};

my $class = 'Apache::Session::Browseable::SQLite';
use_ok($class);

my $args  = { DataSource => $dsn, Commit => 1, Index => 'uid' };
my $reuse = { %$args, reuse => 1 };
my $dbhOf = sub { tied( %{ $_[0] } )->{object_store}->{dbh} };
my $newSession = sub {
    my ( $a, %data ) = @_;
    my %session;
    tie %session, $class, undef, $a;
    $session{$_} = $data{$_} foreach ( keys %data );
    my $id = $session{_session_id};
    untie %session;
    return $id;
};

my ( %session, $dbh );

# 1. Without "reuse": a new connection for each session, closed at untie
tie %session, $class, undef, $args;
$session{uid} = 'dwho';
my $id = $session{_session_id};
$dbh = $dbhOf->( \%session );
untie %session;
ok( !$dbh->{Active}, 'Without reuse, the connection is closed at untie' );
tie %session, $class, $id, $args;
isnt( refaddr( $dbhOf->( \%session ) ),
    refaddr($dbh), 'Without reuse, each session opens a new connection' );
untie %session;

# 2. With "reuse": the same handle for each session
tie %session, $class, undef, $reuse;
$session{uid} = 'rtyler';
$id  = $session{_session_id};
$dbh = $dbhOf->( \%session );
is( $dbh->{AutoCommit}, '', 'Same attributes as without reuse (AutoCommit)' );
{
    local $SIG{__WARN__} = sub { };    # sqlite_unicode is deprecated
    ok( $dbh->{sqlite_unicode}, 'Same flags as without reuse' );
}
untie %session;
ok( $dbh->{Active}, 'With reuse, the connection is kept at untie' );
ok( $stored->($id), 'Session committed' );
ok( $canWrite->(),  'No transaction left open' );

tie %session, $class, $id, $reuse;
is( refaddr( $dbhOf->( \%session ) ), refaddr($dbh), 'Handle reused' );
is( $session{uid}, 'rtyler', 'Session data retrieved' );
$session{uid} = 'rtyler2';
untie %session;
ok( $canWrite->(), 'No transaction left open after an update' );
tie %session, $class, $id, $args;
is( $session{uid}, 'rtyler2', 'Update committed' );
untie %session;

my $res = $class->searchOn( $reuse, 'uid', 'rtyler2' );
is_deeply( [ keys %$res ], [$id], 'searchOn works with reuse' );

# 3. Without Commit, the transaction is rolled back at untie (as disconnect
# did), and doesn't stay open
tie %session, $class, $id, { %$reuse, Commit => 0 };
is( refaddr( $dbhOf->( \%session ) ), refaddr($dbh), 'Handle reused' );
$session{uid} = 'not committed';
untie %session;
ok( $canWrite->(), 'Commit => 0: no transaction left open' );
tie %session, $class, $id, $reuse;
is( $session{uid}, 'rtyler2', 'Commit => 0: update rolled back' );
untie %session;

# 4. A failed operation doesn't break the next ones
ok( !eval { tie %session, $class, 'unknown', $reuse; 1 },
    'Unknown session: tie fails' );
ok(
    !$quiet->(
        sub { $newSession->( { %$reuse, TableName => 'missing' }, uid => 'x' ) }
    ),
    'Failed insert: tie fails'
);
ok( $canWrite->(), 'No transaction left open after failures' );
tie %session, $class, $id, $reuse;
is( refaddr( $dbhOf->( \%session ) ), refaddr($dbh), 'Handle still reused' );
is( $session{uid}, 'rtyler2', 'Session retrieved after failures' );
untie %session;

# 5. Deletion
my $id2 = $newSession->( $reuse, uid => 'deleted' );
tie %session, $class, $id2, $reuse;
tied(%session)->delete;
untie %session;
ok( !$stored->($id2), 'Session deleted' );
ok( !eval { tie %session, $class, $id2, $reuse; 1 },
    'Deleted session is not found' );

# 6. A given Handle wins
my $mine = DBI->connect( $dsn, '', '', { RaiseError => 1, AutoCommit => 0 } );
tie %session, $class, $id, { %$reuse, Handle => $mine };
is( refaddr( $dbhOf->( \%session ) ), refaddr($mine), 'Given Handle is used' );
untie %session;
ok( $mine->{Active}, 'Given Handle is not closed' );

# 7. Lost connection: a new one is opened
$dbh->disconnect;
tie %session, $class, $id, $reuse;
my $new = $dbhOf->( \%session );
ok( ( $new->{Active} and refaddr($new) != refaddr($dbh) ),
    'Lost connection replaced' );
is( $session{uid}, 'rtyler2', 'Session retrieved with the new connection' );
untie %session;
tie %session, $class, $id, $reuse;
is( refaddr( $dbhOf->( \%session ) ), refaddr($new), 'New handle reused' );
untie %session;

# 8. Each store keeps the attributes of its own connections. The upstream
# stores only use SQL that SQLite understands, except "SELECT ... FOR UPDATE"
# in materialize(), which provides a failure
my %stores = (
    Postgres    => [ 0, 1 ],
    Oracle      => [ 0, 1 ],
    Informix    => [ 0, 1 ],
    Patroni     => [ 0, 0 ],
    SQLite      => [ 0, 0 ],
    MySQL       => [ 1, 0 ],
    MariaDBJSON => [ 1, 0 ],
    Cassandra   => [ 1, 1 ],
);
my $n = 0;
foreach my $name ( sort keys %stores ) {
    my ( $autoCommit, $failingMaterialize ) = @{ $stores{$name} };
    my $store = "Apache::Session::Browseable::Store::$name";
    use_ok($store);
    my $session = sub {
        my ( $sid, %a ) = @_;
        return {
            args => { DataSource => $dsn, Commit => 1, reuse => 1, %a },
            data => { _session_id => $sid },
            serialized => '{}',
        };
    };
    my ( $s, $sid, $d ) = ( $store->new, "$name-" . $n++ );
    $s->insert( $session->($sid) );
    $d = $s->{dbh};
    is( $d->{AutoCommit} ? 1 : 0, $autoCommit, "$name: AutoCommit" );
    undef $s;
    ok( $d->{Active},        "$name: connection kept" );
    ok( $stored->($sid),     "$name: session stored" );
    ok( $canWrite->(),       "$name: no transaction left open" );

    $s = $store->new;
    $s->connection( $session->($sid) );
    is( refaddr( $s->{dbh} ), refaddr($d), "$name: handle reused" );
    undef $s;

    # Without Commit, the insertion is rolled back when AutoCommit is off
    ( $s, $sid ) = ( $store->new, "$name-" . $n++ );
    $s->insert( $session->( $sid, Commit => 0 ) );
    undef $s;
    is( $stored->($sid) ? 1 : 0, $autoCommit, "$name: Commit => 0" );
    ok( $canWrite->(), "$name: Commit => 0: no transaction left open" );

    if ($failingMaterialize) {
        $s = $store->new;
        ok( !$quiet->( sub { $s->materialize( $session->($sid) ) } ),
            "$name: materialize() fails with SQLite" );
        undef $s;
        ok( $canWrite->(), "$name: no transaction left open after failure" );
    }
}

done_testing();
