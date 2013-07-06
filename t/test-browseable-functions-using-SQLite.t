# Complete tests with SQLite

use strict;
use warnings;
use Test::More;

my $dbfile = 'tmp.db';

plan skip_all => "DBD::SQLite is needed for this test"
  unless eval {
    require DBI;
    require DBD::SQLite;
    unlink 'tmp.db' if ( -e 'tmp.db' );
    1;
  };

plan skip_all => "DBD::SQLite error : $@"
  unless eval {
    my $dbh;
    $dbh = DBI->connect( "dbi:SQLite:dbname=$dbfile", "", "" )
      or die $dbh->errstr;
    $dbh->do(
'CREATE TABLE sessions(id char(32) not null primary key,a_session text,f1 text,f2 text);'
    )                                                 or die $dbh->errstr;
    $dbh->do('CREATE INDEX f1_idx ON sessions (f1);') or die $dbh->errstr;
    $dbh->do('CREATE INDEX f2_idx ON sessions (f2);') or die $dbh->errstr;
    $dbh->disconnect()                                or die $dbh->errstr;
  };

my @list = ( "aa" .. "az", "aa" .. "ac" );
my $count = @list;

plan tests => 15 + $count;

use_ok('Apache::Session::Browseable::SQLite');

my %session;
my $args = { DataSource => "dbi:SQLite:$dbfile", Index => "f1 f2", };
foreach (@list) {
    ok( tie %session, 'Apache::Session::Browseable::SQLite',
        undef, $args, "Create session $_" );
    $session{f1} = "1_$_";
    $session{f2} = "2_$_";
    $session{f3} = "3_$_";
    $session{f4} = "4_$_";
    untie %session;
}

my $res;

# 1. Get simply all sessions
ok(
    $res =
      Apache::Session::Browseable::SQLite->get_key_from_all_sessions($args),
    'Get all sessions'
);
ok( count($res) == $count,
    "get_key_from_all_sessions returns $count sessions (".count($res).")" );

# 2. Test searchOn() on an indexed field
ok( $res = Apache::Session::Browseable::SQLite->searchOn( $args, 'f1', '1_aa' ));
ok( count($res) == 2, 'Get 2 "aa" sessions ('.count($res).")" );
ok( $res = Apache::Session::Browseable::SQLite->searchOn( $args, 'f1', '1_ad' ));
ok( count($res) == 1, 'Get 1 "ad" sessions ('.count($res).")" );

# 3. Test searchOn() on an unindexed field
ok( $res = Apache::Session::Browseable::SQLite->searchOn( $args, 'f3', '3_aa' ));
ok( count($res) == 2, 'Get 2 "aa" sessions ('.count($res).")" );
ok( $res = Apache::Session::Browseable::SQLite->searchOn( $args, 'f3', '3_ad' ));
ok( count($res) == 1, 'Get 1 "ad" sessions ('.count($res).")" );

# 4. Test searchOnExpr() on an indexed field
ok( $res = Apache::Session::Browseable::SQLite->searchOnExpr( $args, 'f1', '*aa' ));
ok( count($res) == 2, 'Get 2 "aa" sessions ('.count($res).")" );

# 5. Test searchOnExpr() on an unindexed field
ok( $res = Apache::Session::Browseable::SQLite->searchOnExpr( $args, 'f3', '*aa' ));
ok( count($res) == 2, 'Get 2 "aa" sessions ('.count($res).")" );

1;

sub count {
    my @c = keys %{ $_[0] };
    return scalar @c;
}
