use strict;
use lib 't/lib';
use SQLBackendTests;

run_tests(
    class  => 'Apache::Session::Browseable::Postgres',
    driver => 'Pg',
    env    => 'PG',
    table  => 'asb_test_postgres',
    create => [
            'CREATE TABLE __TABLE__ (id varchar(64) not null primary key,'
          . ' a_session text, uid text, _whatToTrace text, _session_kind text,'
          . ' _utime bigint, _lastSeen bigint)'
    ],
    index => 'uid _whatToTrace _session_kind _utime _lastSeen',
    todo  => {
        deleteNot       => 'sessions without the "not" field are never deleted',
        deleteAndNot    => 'sessions without the "not" field are never deleted',
        ruleNotModified => '"not" values of the rule are escaped in place',
        gkfasField      => 'field names are returned lower-cased',
    },
);
