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
    todo => {
        deleteNot      => 'sessions without the "not" field are never deleted',
        deleteAndNot   => 'sessions without the "not" field are never deleted',
        deleteNotQuote => '"not" values are not escaped',
    },
);
