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

# get_key_from_all_sessions reads sessions by batches
{
    no warnings 'once';
    local $Apache::Session::Browseable::_common::BatchSize = 2;
    my $queries = 0;
    my $cdbh    = $class->_classDbh($args);
    local $cdbh->{Callbacks} =
      { ChildCallbacks => { execute => sub { $queries++; return } } };
    foreach my $n ( 4, 5 ) {
        $ids = reset_sessions( map { ( "s$_" => { uid => "u$_" } ) } 1 .. $n );
        $queries = 0;
        my $calls = 0;
        $res = $class->get_key_from_all_sessions( $args,
            sub { $calls++; $_[0]->{uid} } );
        is( $calls, $n, "$n sessions by batches: callback called for each" );
        is_deeply(
            $res,
            { map { ( $ids->{"s$_"} => "u$_" ) } 1 .. $n },
            "$n sessions by batches: all sessions returned"
        );
        is( $queries, 3, "$n sessions by batches: 3 queries" );
        $res = $class->get_key_from_all_sessions($args);
        is(
            join( ',', sort map { $_->{uid} } values %$res ),
            join( ',', map { "u$_" } 1 .. $n ),
            "$n sessions by batches: all sessions returned without callback"
        );
    }
}

# 11. Invalid batch sizes fall back to the default one
{
    no warnings 'once';
    $ids = reset_sessions( map { ( "s$_" => { uid => "u$_" } ) } 1 .. 3 );
    foreach my $size ( 0, -1, 'abc', undef, 1_000_001, '9' x 26 ) {
        local $Apache::Session::Browseable::_common::BatchSize = $size;
        my $name = defined $size ? "'$size'" : 'undef';
        $res = eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm 10;
            my $r = $class->get_key_from_all_sessions($args);
            alarm 0;
            $r;
        };
        alarm 0;
        is( $@, '', "BatchSize $name: terminates" );
        is( join( ',', sort map { $_->{uid} } values %{ $res || {} } ),
            'u1,u2,u3', "BatchSize $name: all sessions returned" );
    }
}

# 12. Subclass without its own populate()
{

    package My::SQLiteSubclass;
    our @ISA = ('Apache::Session::Browseable::SQLite');
}
$res = eval { My::SQLiteSubclass->get_key_from_all_sessions($args) };
is( $@, '', 'Subclass without populate: no error' );
is( join( ',', sort map { $_->{uid} } values %{ $res || {} } ),
    'u1,u2,u3', 'Subclass without populate: all sessions returned' );
$res = eval {
    My::SQLiteSubclass->get_key_from_all_sessions( $args,
        sub { $_[0]->{uid} } );
};
is( join( ',', sort values %{ $res || {} } ),
    'u1,u2,u3', 'Subclass without populate: callback called' );

done_testing();

END {
    unlink $dbfile if ( $dbfile and -e $dbfile );
}
