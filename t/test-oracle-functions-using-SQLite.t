# Common SQL tests of the Oracle backend, run on SQLite: it accepts the
# double-quoted index columns and, like Oracle, returns the declared names of
# unquoted columns (ID, A_SESSION). Unlike Oracle, it doesn't check the case
# of quoted names nor reject unquoted names starting with "_": see
# t/Apache-Session-Browseable-quoteColumn.t for the queries themselves

use strict;
use warnings;
use lib 't/lib';
use File::Temp qw(tempdir);
use SQLBackendTests;

my $dir = tempdir( CLEANUP => 1 );
$ENV{ORACLE_SQLITE_DSN} = "dbi:SQLite:dbname=$dir/sessions.db";
delete @ENV{qw(ORACLE_SQLITE_USER ORACLE_SQLITE_PASSWORD)};

# Field names that can't be used unquoted
my @weird = ( 'a"b', 'x y' );

run_tests(
    class  => 'Apache::Session::Browseable::Oracle',
    driver => 'SQLite',
    env    => 'ORACLE_SQLITE',
    table  => 'asb_test_oracle',
    create => [
        'CREATE TABLE __TABLE__ (ID varchar(64) not null primary key,'
          . ' A_SESSION text, "uid" varchar(255), "_whatToTrace" varchar(255),'
          . ' "_session_kind" varchar(32), "_utime" integer,'
          . ' "_lastSeen" integer, "_oidcRtUpdate" integer,'
          . ' "a""b" varchar(32), "x y" varchar(32))',
        'CREATE INDEX __TABLE___u1 ON __TABLE__ ("_utime")',
    ],
    index => [
        qw(uid _whatToTrace _session_kind _utime _lastSeen _oidcRtUpdate),
        @weird
    ],
    weird   => \@weird,
    corrupt => 'not json',
    todo    => {
        searchOnExprQuote => 'quotes are doubled although the value is bound',
        deleteNot       => 'sessions without the "not" field are never deleted',
        deleteAndNot    => 'sessions without the "not" field are never deleted',
        ruleNotModified => '"not" values of the rule are escaped in place',
    },
);
