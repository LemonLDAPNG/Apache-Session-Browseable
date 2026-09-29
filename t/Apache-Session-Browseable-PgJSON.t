use strict;
use lib 't/lib';
use SQLBackendTests;

run_tests(
    class  => 'Apache::Session::Browseable::PgJSON',
    driver => 'Pg',
    env    => 'PG',
    table  => 'asb_test_pgjson',
    create => [
'CREATE TABLE __TABLE__ (id varchar(64) not null primary key, a_session jsonb)',
        'CREATE INDEX __TABLE___uid1 ON __TABLE__ USING BTREE'
          . " ( (a_session ->> '_whatToTrace') text_pattern_ops )",
        'CREATE INDEX __TABLE___u1 ON __TABLE__'
          . " ( ( cast(a_session ->> '_utime' AS bigint) ) )",
    ],
    todo => {
        deleteAnd      => '"and" rules are built from the "or" hash',
        deleteNot      => 'sessions without the "not" field are never deleted',
        deleteAndNot   => '"and" rules are built from the "or" hash',
        deleteNotQuote => '"not" values are not escaped',
    },
    explain => sub {
        my $wt = "a_session ->> '_whatToTrace'";
        my $ut = "a_session ->> '_utime'";
        return (
            [
                'deleteIfLowerThan', "cast($ut as bigint) < 200",
                '__TABLE___u1'
            ],
            [ 'searchOnExpr', "$wt like 'dw%'", '__TABLE___uid1' ],
            [ 'searchOn',     "$wt = 'dwho'",   '__TABLE___uid1' ],
        );
    },
);
