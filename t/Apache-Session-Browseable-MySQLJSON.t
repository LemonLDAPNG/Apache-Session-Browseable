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
    weird => [ "weird'field", 'a"b\\c' ],
);
