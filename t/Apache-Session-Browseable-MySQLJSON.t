use strict;
use lib 't/lib';
use SQLBackendTests;

run_tests(
    class  => 'Apache::Session::Browseable::MySQLJSON',
    driver => 'mysql',
    env    => 'MYSQL',
    table  => 'asb_test_mysqljson',
    create => [
'CREATE TABLE __TABLE__ (id varchar(64) not null primary key, a_session json)'
    ],
    json  => 1,
    weird => [ "weird'field", 'a"b\\c', 'a?b', 'x\\' ],
    todo  => {
        searchOnData => 'session data is not decoded',
        gkfasArray   => 'the query does not select the id column',
        gkfasField   => 'the query does not select the id column',
        deleteAnd    => '"and" rules are built from the "or" hash',
        deleteNot    => 'sessions without the "not" field are never deleted',
        deleteAndNot => '"and" rules are built from the "or" hash',
    },
);
