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
    json    => 1,
    scs     => 1,
    weird   => [ "weird'field", 'a?b' ],
    corrupt => '"x"=>"_json://{bad"',
);
