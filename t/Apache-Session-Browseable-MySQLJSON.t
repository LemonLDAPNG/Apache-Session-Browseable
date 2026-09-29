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
    todo => {
        searchOnData   => 'session data is not decoded',
        searchOnFields => 'field names are returned lower-cased',
        gkfasArray     => 'the query does not select the id column',
        gkfasField     => 'the query does not select the id column',
        deleteAnd      => '"and" rules are built from the "or" hash',
        deleteNot      => 'sessions without the "not" field are never deleted',
        deleteAndNot   => '"and" rules are built from the "or" hash',
        deleteNotQuote => '"not" values are not escaped',
    },
    explain => sub {
        my ( $wt, $sk, $ut ) =
          map { qq{a_session->>"\$.$_"} } qw(_whatToTrace _session_kind _utime);
        return (
            [ 'deleteIfLowerThan', "cast($ut as UNSIGNED) < 200", 'as_ut' ],
            [
                'deleteIfLowerThan with "not"',
                "(cast($ut as UNSIGNED) < 200) AND $sk <> 'Persistent'",
                'as_ut'
            ],
            [ 'searchOn', "$wt = 'dwho'", 'as_wt' ],
        );
    },
);
