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
          . ' a_session text, uid varchar(64) COLLATE utf8mb4_bin,'
          . ' _whatToTrace varchar(64) COLLATE utf8mb4_bin,'
          . ' _session_kind varchar(64) COLLATE utf8mb4_bin,'
          . ' _utime bigint, _lastSeen bigint)',
        'CREATE INDEX u1 ON __TABLE__ (_utime)',
        'CREATE INDEX ls1 ON __TABLE__ (_lastSeen)',
        'CREATE INDEX uid1 ON __TABLE__ (_whatToTrace) USING BTREE',
    ],
    exact => 1,
    index => 'uid _whatToTrace _session_kind _utime _lastSeen',
    todo  => {
        searchOnExprQuote => 'quotes are doubled although the value is bound',
        deleteNot    => 'sessions without the "not" field are never deleted',
        deleteAndNot => 'sessions without the "not" field are never deleted',
    },
    explain => sub {
        my ($class) = @_;
        my ( $ut, $ls ) =
          map { $class->_buildLowerThanExpression( $_, 200 ) }
          qw(_utime _lastSeen);
        my $sk = '_session_kind';
        return (
            [ 'deleteIfLowerThan', $ut, 'u1' ],
            [
                'deleteIfLowerThan "or" with "not"',
                "($ut OR $ls) AND ($sk IS NULL OR $sk <> 'Persistent')",
                [ 'u1', 'ls1' ]
            ],
            [ 'searchOnExpr', "_whatToTrace LIKE 'dw%'", 'uid1' ],
        );
    },
);
