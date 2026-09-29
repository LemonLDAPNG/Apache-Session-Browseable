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
    json    => 1,
    null    => 1,
    weird   => [ "weird'field", 'a"b\\c', 'a?b', 'x\\' ],
    scs     => 1,
    explain => sub {
        my ($class) = @_;
        my $wt      = $class->_sqlField('_whatToTrace');
        my $ut      = $class->_sqlField('_utime');
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
