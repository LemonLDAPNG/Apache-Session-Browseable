use strict;
use lib 't/lib';
use SQLBackendTests;

# Index columns are created with quoted names: Oracle rejects unquoted names
# starting with "_", and quoted names are case sensitive
run_tests(
    class  => 'Apache::Session::Browseable::Oracle',
    driver => 'Oracle',
    env    => 'ORACLE',
    table  => 'asb_test_oracle',
    create => [
        'CREATE TABLE __TABLE__ (id varchar2(64) not null primary key,'
          . ' a_session clob, "uid" varchar2(255),'
          . ' "_whatToTrace" varchar2(255), "_session_kind" varchar2(32),'
          . ' "_utime" number(20), "_lastSeen" number(20),'
          . ' "_oidcRtUpdate" number(20))',
        'CREATE INDEX __TABLE___u1 ON __TABLE__ ("_utime")',
        'CREATE INDEX __TABLE___ls1 ON __TABLE__ ("_lastSeen")',
        'CREATE INDEX __TABLE___rt1 ON __TABLE__ ("_oidcRtUpdate")',
        'CREATE INDEX __TABLE___uid1 ON __TABLE__ ("_whatToTrace")',
    ],
    index   => 'uid _whatToTrace _session_kind _utime _lastSeen _oidcRtUpdate',
    corrupt => 'not json',
    todo    => {
        searchOnExprQuote => 'quotes are doubled although the value is bound',
        deleteNot       => 'sessions without the "not" field are never deleted',
        deleteAndNot    => 'sessions without the "not" field are never deleted',
        ruleNotModified => '"not" values of the rule are escaped in place',
    },
);
