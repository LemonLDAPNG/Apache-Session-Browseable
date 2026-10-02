package SQLBackendTests;

# Common tests for SQL backends, run only if <env>_DSN is set (credentials
# are read from <env>_USER and <env>_PASSWORD). Parameters:
#  - class:   Apache::Session::Browseable class to test
#  - driver:  DBD driver name (Pg, mysql)
#  - env:     environment variables prefix (PG, MYSQL)
#  - table:   table name (dropped before and after tests)
#  - create:  SQL statements to create table (__TABLE__ is replaced)
#  - index:   indexed fields (DBI based backends, one column per field)
#  - json:    1 if any field can be queried (JSON/Hstore backends)
#  - weird:   field names that need quoting (JSON/Hstore backends)
#  - scs:     1 to also test with standard_conforming_strings=off (PostgreSQL)
#  - todo:    known bugs of this backend: { test group => reason }. Tests of
#             these groups are run as TODO tests and may die without
#             breaking the rest of the suite

use strict;
use warnings;
use Test::More;
use Exporter 'import';

our @EXPORT = qw(run_tests);
our $TODO;

sub run_tests {
    my %o = @_;
    my ( $class, $table ) = @o{qw(class table)};
    my $dsn = $ENV{"$o{env}_DSN"};

    plan skip_all => "DBD::$o{driver} is needed for this test"
      unless eval "require DBI; require DBD::$o{driver}; 1";
    plan skip_all => "Set $o{env}_DSN to run this test" unless $dsn;

    my $dbh = DBI->connect(
        $dsn, $ENV{"$o{env}_USER"},
        $ENV{"$o{env}_PASSWORD"},
        { RaiseError => 1, PrintError => 0, PrintWarn => 0, AutoCommit => 1 }
    );
    $dbh->do("DROP TABLE IF EXISTS $table");
    foreach ( @{ $o{create} } ) {
        ( my $sql = $_ ) =~ s/__TABLE__/$table/g;
        $dbh->do($sql);
    }

    use_ok($class);

    my $args = {
        DataSource => $dsn,
        UserName   => $ENV{"$o{env}_USER"},
        Password   => $ENV{"$o{env}_PASSWORD"},
        TableName  => $table,
        Commit     => 1,
        ( $o{index} ? ( Index => $o{index} ) : () ),
    };
    my %todo  = %{ $o{todo}  || {} };
    my @weird = @{ $o{weird} || [] };

    my $newSession = sub {
        my %data = @_;
        my %session;
        tie %session, $class, undef, $args;
        $session{$_} = $data{$_} foreach ( keys %data );
        my $id = $session{_session_id};
        untie %session;
        return $id;
    };

    my %data = (
        dwho => {
            uid           => 'dwho',
            _whatToTrace  => 'dwho',
            _session_kind => 'SSO',
            _utime        => 100,
            _lastSeen     => 100,
            mail          => 'dwho@badwolf.org',
            ( map { ( $_ => 'w1' ) } @weird ),
        },
        rtyler => {
            uid           => 'rtyler',
            _whatToTrace  => 'rtyler',
            _session_kind => 'Persistent',
            _utime        => 100,
            _lastSeen     => 300,
            mail          => 'rtyler@badwolf.org',
            ( map { ( $_ => 'w2' ) } @weird ),
        },
        obrien => {
            uid           => "O'Brien",
            _whatToTrace  => "O'Brien",
            _session_kind => 'SSO',
            _utime        => 300,
            _lastSeen     => 100,
            mail          => 'obrien@badwolf.org',
        },
        nokind => {
            uid          => 'nokind',
            _whatToTrace => 'nokind',
            _utime       => 100,
            _lastSeen    => 100,
            mail         => 'nokind@badwolf.org',
        },
    );

    my $ids;
    my $reset = sub {
        $dbh->do("DELETE FROM $table");
        $ids = { map { ( $_ => $newSession->( %{ $data{$_} } ) ) } keys %data };
    };
    my $name = sub {
        my %rev = reverse %{ $ids || {} };
        return join ',', sort map { $rev{$_} // $_ } keys %{ $_[0] || {} };
    };
    my $remaining = sub {
        return $name->( $class->get_key_from_all_sessions($args) );
    };
    my $quiet = sub {
        my ($code) = @_;
        local *STDERR;
        my $err = '';
        open STDERR, '>', \$err;
        return $code->();
    };

    # Run a group of tests. If the group is a known bug of this backend, run
    # it as TODO: STDERR is silenced and a die is reported as a failure
    my $group = sub {
        my ( $key, $code ) = @_;
        return $code->() unless $todo{$key};
      TODO: {
            local $TODO = $todo{$key};
            local *STDERR;
            my $err = '';
            open STDERR, '>', \$err;
            eval { $code->(); 1 } or fail("$key died: $@");
        }
    };

    # Store / retrieve
    $group->(
        store => sub {
            my $id = $newSession->( %{ $data{dwho} }, list => [ 1, 2 ] );
            ok( $id, 'Session created' );
            my %session;
            ok( tie( %session, $class, $id, $args ), 'Session retrieved' );
            is( $session{$_}, $data{dwho}->{$_}, "Field $_ retrieved" )
              foreach ( sort keys %{ $data{dwho} } );
            is_deeply( $session{list}, [ 1, 2 ], 'Array retrieved' );
            untie %session;
        }
    );

    $reset->();

    # searchOn / searchOnExpr
    $group->(
        searchOn => sub {
            my $res = $class->searchOn( $args, 'uid', 'dwho' );
            is( $name->($res), 'dwho', 'searchOn without fields' );

            $res = $class->searchOn( $args, '_whatToTrace', "O'Brien", 'uid' );
            is_deeply(
                $res,
                {
                    $ids->{obrien} => { id => $ids->{obrien}, uid => "O'Brien" }
                },
                'searchOn on a value containing a quote'
            );

            $res = $class->searchOn( $args, '_session_kind', 'SSO', '_utime' );
            is( $name->($res), 'dwho,obrien', 'searchOn on _session_kind' );

            $res = $class->searchOnExpr( $args, '_whatToTrace', '*t*' );
            is( $name->($res), 'rtyler', 'searchOnExpr without fields' );
        }
    );
    $group->(
        searchOnData => sub {
            my $res = $class->searchOn( $args, 'uid', 'dwho' );
            is( $res->{ $ids->{dwho} }->{mail},
                'dwho@badwolf.org',
                'searchOn without fields returns session data' );
            $res = $class->searchOnExpr( $args, 'uid', 'dw*' );
            is( $res->{ $ids->{dwho} }->{mail},
                'dwho@badwolf.org',
                'searchOnExpr without fields returns session data' );
        }
    );
    $group->(
        searchOnFields => sub {
            my $res =
              $class->searchOn( $args, 'uid', 'dwho', '_whatToTrace', 'uid' );
            is_deeply(
                $res,
                {
                    $ids->{dwho} => {
                        id           => $ids->{dwho},
                        _whatToTrace => 'dwho',
                        uid          => 'dwho'
                    }
                },
                'searchOn with fields keeps field name case'
            );
            $res =
              $class->searchOnExpr( $args, '_whatToTrace', '*t*',
                '_whatToTrace' );
            is_deeply(
                $res,
                {
                    $ids->{rtyler} =>
                      { id => $ids->{rtyler}, _whatToTrace => 'rtyler' }
                },
                'searchOnExpr with fields keeps field name case'
            );
        }
    );
    $group->(
        searchOnExprQuote => sub {
            my $res = $class->searchOnExpr( $args, 'uid', "O'Br*" );
            is( $name->($res), 'obrien',
                'searchOnExpr on a value containing a quote' );
        }
    );

    # get_key_from_all_sessions
    $group->(
        gkfas => sub {
            my $res = $class->get_key_from_all_sessions($args);
            is( $name->($res), 'dwho,nokind,obrien,rtyler',
                'get_key_from_all_sessions without argument' );
            is( $res->{ $ids->{rtyler} }->{mail},
                'rtyler@badwolf.org',
                'get_key_from_all_sessions returns session data' );

            $res = $class->get_key_from_all_sessions( $args,
                sub { $_[0]->{uid} eq 'dwho' ? $_[0]->{mail} : undef } );
            is_deeply(
                $res,
                { $ids->{dwho} => 'dwho@badwolf.org' },
                'get_key_from_all_sessions with a code ref'
            );
        }
    );
    $group->(
        gkfasArray => sub {
            my $fields = [ 'uid', '_utime' ];
            my $res    = $class->get_key_from_all_sessions( $args, $fields );
            is( $name->($res), 'dwho,nokind,obrien,rtyler',
                'get_key_from_all_sessions with an array ref' );
            is( $res->{ $ids->{obrien} }->{uid},
                "O'Brien",
                'get_key_from_all_sessions with an array ref returns data' );
            is_deeply(
                $fields,
                [ 'uid', '_utime' ],
                'Array ref is not modified'
            );
        }
    );
    $group->(
        gkfasField => sub {
            my $res =
              $class->get_key_from_all_sessions( $args, '_whatToTrace' );
            is_deeply(
                $res->{ $ids->{rtyler} },
                { id => $ids->{rtyler}, _whatToTrace => 'rtyler' },
                'get_key_from_all_sessions with a field name'
            );
        }
    );

    # Fields needing quotes
    foreach my $w (@weird) {
        $group->(
            weird => sub {
                my $res = $class->searchOn( $args, $w, 'w1', $w, 'uid' );
                is_deeply(
                    $res,
                    {
                        $ids->{dwho} =>
                          { id => $ids->{dwho}, $w => 'w1', uid => 'dwho' }
                    },
                    "searchOn on field [$w]"
                );
                $res = $class->searchOnExpr( $args, $w, 'w*', 'uid' );
                is( $name->($res), 'dwho,rtyler',
                    "searchOnExpr on field [$w]" );
            }
        );
        $group->(
            gkfasArray => sub {
                my $res =
                  $class->get_key_from_all_sessions( $args, [ $w, 'uid' ] );
                is( $res->{ $ids->{rtyler} }->{$w},
                    'w2', "get_key_from_all_sessions with field [$w]" );
            }
        );
    }
    if ( $o{json} ) {
        foreach my $w ( "x' OR '1'='1", 'x" OR "1"="1', "x`y" ) {
            $group->(
                fieldInjection => sub {
                    my $res = eval { $class->searchOn( $args, $w, 'w1', $w ) };
                    is_deeply( $res, {},
                        "searchOn on field [$w]: no injection" )
                      or diag $@;
                }
            );
            $group->(
                gkfasArray => sub {
                    my $res =
                      eval { $class->get_key_from_all_sessions( $args, [$w] ); };
                    is( scalar( keys %{ $res || {} } ),
                        4, "get_key_from_all_sessions with field [$w]" )
                      or diag $@;
                }
            );
        }
    }

    # deleteIfLowerThan
    $group->(
        delete => sub {
            $reset->();
            my @r =
              $class->deleteIfLowerThan( $args, { or => { _utime => 200 } } );
            is_deeply(
                \@r,
                [ 1, 3 ],
                'deleteIfLowerThan "or": 3 sessions deleted'
            );
            is( $remaining->(), 'obrien',
                'deleteIfLowerThan "or": 1 session kept' );

            $reset->();
            @r = $class->deleteIfLowerThan( $args,
                { or => { _utime => 200, _lastSeen => 200 } } );
            is_deeply( \@r, [ 1, 4 ], 'deleteIfLowerThan "or" with 2 fields' );
        }
    );
    $group->(
        deleteAnd => sub {
            $reset->();
            my @r = $class->deleteIfLowerThan( $args,
                { and => { _utime => 200, _lastSeen => 200 } } );
            is_deeply(
                \@r,
                [ 1, 2 ],
                'deleteIfLowerThan "and": 2 sessions deleted'
            );
            is( $remaining->(), 'obrien,rtyler',
                'deleteIfLowerThan "and": 2 kept' );
        }
    );
    $group->(
        deleteNot => sub {
            $reset->();
            my @r = $class->deleteIfLowerThan(
                $args,
                {
                    or  => { _utime        => 200 },
                    not => { _session_kind => 'Persistent' }
                }
            );
            is_deeply(
                \@r,
                [ 1, 2 ],
                'deleteIfLowerThan "not": 2 sessions deleted'
            );
            is( $remaining->(), 'obrien,rtyler',
                'deleteIfLowerThan "not": session without field deleted' );
        }
    );
    $group->(
        deleteAndNot => sub {
            $reset->();
            my @r = $class->deleteIfLowerThan(
                $args,
                {
                    and => { _utime        => 200, _lastSeen => 400 },
                    not => { _session_kind => 'Persistent' }
                }
            );
            is_deeply( \@r, [ 1, 2 ], 'deleteIfLowerThan "and" with "not"' );
            is( $remaining->(), 'obrien,rtyler',
                'deleteIfLowerThan "and" with "not": right sessions kept' );
        }
    );
    $group->(
        deleteNotQuote => sub {
            $reset->();
            my @r = $class->deleteIfLowerThan( $args,
                { or => { _utime => 400 }, not => { uid => "O'Brien" } } );
            is_deeply( \@r, [ 1, 3 ], 'deleteIfLowerThan "not" with a quote' );
            is( $remaining->(), 'obrien',
                'deleteIfLowerThan "not" with a quote' );

            $reset->();
            @r = $class->deleteIfLowerThan( $args,
                { or => { _utime => 400 }, not => { uid => "x' OR '1'='1" } } );
            is_deeply( \@r, [ 1, 4 ], 'deleteIfLowerThan "not": no injection' );
        }
    );
    $group->(
        ruleNotModified => sub {
            $reset->();
            my $rule =
              { or => { _utime => 400 }, not => { uid => "O'Brien" } };
            {
                # Some backends die here, only the rule matters
                local *STDERR;
                my $err = '';
                open STDERR, '>', \$err;
                eval { $class->deleteIfLowerThan( $args, $rule ) };
            }
            is( $rule->{not}->{uid}, "O'Brien", 'Rule is not modified' );
        }
    );

    # Thresholds are inserted into the query: they must be numbers
    $group->(
        deleteThresholds => sub {
            $reset->();
            foreach my $type (qw(or and)) {
                foreach my $bad ( '200 OR 1=1', '1e3', '', "\x{0661}" ) {
                    ( my $label = $bad ) =~ s/[^ -~]/?/g;
                    my @r = $quiet->(
                        sub {
                            eval {
                                $class->deleteIfLowerThan(
                                    $args,
                                    {
                                        $type =>
                                          { _utime => 400, _lastSeen => $bad }
                                    }
                                );
                            };
                        }
                    );
                    is_deeply(
                        \@r,
                        [ 0, 0 ],
                        "\"$type\" with threshold '$label' returns 0"
                    );
                }
            }
            is( $remaining->(), 'dwho,nokind,obrien,rtyler',
                'Nothing deleted' );

            my @r =
              $class->deleteIfLowerThan( $args,
                { or => { _utime => '100.5' } } );
            is_deeply(
                \@r,
                [ 1, 3 ],
                'deleteIfLowerThan with a decimal threshold'
            );
        }
    );

    # "not" on fields needing quotes. Sessions without the field must be
    # deleted too
    foreach my $w (@weird) {
        $group->(
            deleteNot => sub {
                $reset->();
                my @r = $class->deleteIfLowerThan( $args,
                    { or => { _utime => 400 }, not => { $w => 'w1' } } );
                is_deeply(
                    \@r,
                    [ 1, 3 ],
                    "deleteIfLowerThan \"not\" on field [$w]"
                );
                is( $remaining->(), 'dwho',
                    "deleteIfLowerThan \"not\" on field [$w]" );
            }
        );
    }

    # PostgreSQL with standard_conforming_strings=off: backslashes are escape
    # characters in plain string literals
    if ( $o{scs} ) {
        my $mdbh = $class->_classDbh($args);
        $mdbh->do('SET standard_conforming_strings = off');
        is( $mdbh->selectrow_array('SHOW standard_conforming_strings'),
            'off', 'standard_conforming_strings is off for the module' );
        my %isWeird = map { $_ => 1 } @weird;
        my @names = ( @weird, grep { !$isWeird{$_} } "x\\' OR '1'='1", 'x\\' );
        foreach my $w (@names) {
            my $found = $isWeird{$w};
            my $l     = "field [$w] (scs off)";
            $reset->();
            $group->(
                weird => sub {
                    my $res =
                      eval { $class->searchOn( $args, $w, 'w1', 'uid' ) };
                    diag $@ if $@;
                    is( $name->($res), $found ? 'dwho' : '', "searchOn on $l" );
                    $res =
                      eval { $class->searchOnExpr( $args, $w, 'w*', 'uid' ) };
                    diag $@ if $@;
                    is(
                        $name->($res),
                        $found ? 'dwho,rtyler' : '',
                        "searchOnExpr on $l"
                    );
                }
            );
            $group->(
                gkfasArray => sub {
                    my $res =
                      eval { $class->get_key_from_all_sessions( $args, [$w] ) };
                    diag $@ if $@;
                    is( scalar( keys %{ $res || {} } ),
                        4, "get_key_from_all_sessions on $l" );
                    is( $res->{ $ids->{rtyler} }->{$w},
                        'w2', "get_key_from_all_sessions value on $l" )
                      if ($found);
                }
            );
            $group->(
                deleteNot => sub {
                    my @r = eval {
                        $class->deleteIfLowerThan( $args,
                            { or => { _utime => 200 }, not => { $w => 'w1' } }
                        );
                    };
                    diag $@ if $@;
                    is_deeply(
                        \@r,
                        [ 1, $found ? 2 : 3 ],
                        "deleteIfLowerThan \"not\" on $l"
                    );
                    is(
                        $remaining->(),
                        $found ? 'dwho,obrien' : 'obrien',
                        "deleteIfLowerThan \"not\" on $l: right sessions kept"
                    );
                }
            );
        }
        $mdbh->do('SET standard_conforming_strings = on');
        is( $mdbh->selectrow_array('SHOW standard_conforming_strings'),
            'on', 'standard_conforming_strings is back on' );
    }

    $dbh->do("DROP TABLE IF EXISTS $table");
    $dbh->disconnect;
    done_testing();
}

1;
