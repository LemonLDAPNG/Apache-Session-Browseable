use strict;
use lib 't/lib';
use SQLBackendTests;

run_tests(
    class  => 'Apache::Session::Browseable::PgHstore',
    driver => 'Pg',
    env    => 'PG',
    table  => 'asb_test_pghstore',
    create => [
        'CREATE EXTENSION IF NOT EXISTS hstore',
'CREATE TABLE __TABLE__ (id varchar(64) not null primary key, a_session hstore)',
        'CREATE INDEX __TABLE___uid1 ON __TABLE__ USING BTREE'
          . " ( (a_session -> '_whatToTrace') text_pattern_ops )",
        'CREATE INDEX __TABLE___u1 ON __TABLE__'
          . " ( ( cast(a_session -> '_utime' AS bigint) ) )",
        'CREATE INDEX __TABLE___ls1 ON __TABLE__'
          . " ( ( cast(a_session -> '_lastSeen' AS bigint) ) )",
    ],
    todo => {
        gkfasArray     => 'the query does not select the id column',
        gkfasField     => 'the query does not select the id column',
        deleteAnd      => '"and" rules are built from the "or" hash',
        deleteNot      => 'sessions without the "not" field are never deleted',
        deleteAndNot   => '"and" rules are built from the "or" hash',
        deleteNotQuote => '"not" values are not escaped',
    },
    explain => sub {
        my ($class) = @_;
        my ( $ut, $ls ) =
          map { $class->_buildLowerThanExpression( $_, 200 ) }
          qw(_utime _lastSeen);
        my ( $wt, $sk ) =
          map { "a_session -> '$_'" } qw(_whatToTrace _session_kind);
        return (
            [ 'deleteIfLowerThan', $ut, '__TABLE___u1' ],
            [
                'deleteIfLowerThan "or" with "not"',
                "($ut OR $ls) AND $sk <> 'Persistent'",
                [ '__TABLE___u1', '__TABLE___ls1' ]
            ],
            [ 'searchOnExpr', "$wt like 'dw%'", '__TABLE___uid1' ],
            [ 'searchOn',     "$wt = 'dwho'",   '__TABLE___uid1' ],
        );
    },
);
