use strict;
use lib 't/lib';
use SQLBackendTests;

run_tests(
    class  => 'Apache::Session::Browseable::MySQL',
    driver => 'mysql',
    env    => 'MYSQL',
    table  => 'asb_test_mysql',
    create => [
            'CREATE TABLE __TABLE__ (id varchar(64) not null primary key,'
          . ' a_session text, uid varchar(64), _whatToTrace varchar(64),'
          . ' _session_kind varchar(64), _utime bigint, _lastSeen bigint)'
    ],
    index => 'uid _whatToTrace _session_kind _utime _lastSeen',
);
