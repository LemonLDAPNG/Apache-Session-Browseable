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
    null => 1,
    todo => {
        searchOnData   => 'session data is not decoded',
        searchOnFields => 'field names are returned lower-cased',
        gkfasArray     => 'the query does not select the id column',
        gkfasField     => 'the query does not select the id column',
        deleteAnd      => '"and" rules are built from the "or" hash',
        deleteAndNot   => '"and" rules are built from the "or" hash',
        deleteNotQuote => '"not" values are not escaped',
    },
);
