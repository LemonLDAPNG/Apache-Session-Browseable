use strict;
use lib 't/lib';
use SQLBackendTests;

run_tests(
    class  => 'Apache::Session::Browseable::PgJSON',
    driver => 'Pg',
    env    => 'PG',
    table  => 'asb_test_pgjson',
    create => [
'CREATE TABLE __TABLE__ (id varchar(64) not null primary key, a_session jsonb)'
    ],
    null => 1,
    todo => {
        deleteAnd      => '"and" rules are built from the "or" hash',
        deleteAndNot   => '"and" rules are built from the "or" hash',
        deleteNotQuote => '"not" values are not escaped',
    },
);
