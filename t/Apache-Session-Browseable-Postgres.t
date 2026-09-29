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
          . ' _utime bigint, _lastSeen bigint)',
        'CREATE INDEX __TABLE___u1 ON __TABLE__ (_utime)',
        'CREATE INDEX __TABLE___ls1 ON __TABLE__ (_lastSeen)',
        'CREATE INDEX __TABLE___uid1 ON __TABLE__'
          . ' USING BTREE (_whatToTrace text_pattern_ops)',
    ],
    index => 'uid _whatToTrace _session_kind _utime _lastSeen',
    todo  => {
        searchOnExprQuote => 'quotes are doubled although the value is bound',
        deleteNot       => 'sessions without the "not" field are never deleted',
        deleteAndNot    => 'sessions without the "not" field are never deleted',
        ruleNotModified => '"not" values of the rule are escaped in place',
        gkfasField      => 'field names are returned lower-cased',
    },
    explain => sub {
        my ($class) = @_;
        my ( $ut, $ls ) =
          map { $class->_buildLowerThanExpression( $_, 200 ) }
          qw(_utime _lastSeen);
        my $sk = '_session_kind';
        return (
            [ 'deleteIfLowerThan', $ut, '__TABLE___u1' ],
            [
                'deleteIfLowerThan "or" with "not"',
                "($ut OR $ls) AND ($sk IS NULL OR $sk <> 'Persistent')",
                [ '__TABLE___u1', '__TABLE___ls1' ]
            ],
            [ 'searchOnExpr', "_whatToTrace LIKE 'dw%'", '__TABLE___uid1' ],
            [ 'searchOn',     "_whatToTrace = 'dwho'",   '__TABLE___uid1' ],
        );
    },
);
