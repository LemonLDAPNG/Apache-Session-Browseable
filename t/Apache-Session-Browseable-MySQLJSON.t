use strict;
use lib 't/lib';
use SQLBackendTests;

# Table with generated columns and indexes as documented
run_tests(
    class  => 'Apache::Session::Browseable::MySQLJSON',
    driver => 'mysql',
    env    => 'MYSQL',
    table  => 'asb_test_mysqljson',
    create => [
            'CREATE TABLE __TABLE__ (id varchar(64) not null primary key,'
          . ' a_session json,'
          . " as_wt varchar(255) AS (a_session->>'\$._whatToTrace') VIRTUAL,"
          . " as_sk varchar(32) AS (a_session->>'\$._session_kind') VIRTUAL,"
          . ' as_ut bigint unsigned'
          . " AS (cast(a_session->>'\$._utime' as unsigned)) VIRTUAL,"
          . " as_ip varchar(64) AS (a_session->>'\$.ipAddr') VIRTUAL,"
          . ' KEY as_wt (as_wt), KEY as_sk (as_sk), KEY as_ut (as_ut),'
          . ' KEY as_ip (as_ip)) ENGINE=InnoDB'
    ],
    json    => 1,
    null    => 1,
    weird   => [ "weird'field", 'a"b\\c', 'a?b', 'x\\' ],
    explain => sub {
        my ( $class, $dbh ) = @_;
        my ( $wt, $sk, $ut ) =
          map { $class->_sqlField( $dbh, $_ ) }
          qw(_whatToTrace _session_kind _utime);
        return (
            [ 'deleteIfLowerThan', "cast($ut as UNSIGNED) < 200", 'as_ut' ],
            [
                'deleteIfLowerThan with "not"',
                "(cast($ut as UNSIGNED) < 200)"
                  . " AND ($sk IS NULL OR $sk <> 'Persistent')",
                'as_ut'
            ],
            [ 'searchOn', "$wt = 'dwho'", 'as_wt' ],
        );
    },
);
