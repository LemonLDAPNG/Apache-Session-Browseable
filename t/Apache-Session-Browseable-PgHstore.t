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
'CREATE TABLE __TABLE__ (id varchar(64) not null primary key, a_session hstore)'
    ],
    json  => 1,
    scs   => 1,
    weird => [ "weird'field", 'a?b' ],
    todo  => {
        gkfasArray   => 'the query does not select the id column',
        gkfasField   => 'the query does not select the id column',
        deleteAnd    => '"and" rules are built from the "or" hash',
        deleteNot    => 'sessions without the "not" field are never deleted',
        deleteAndNot => '"and" rules are built from the "or" hash',
    },
);
