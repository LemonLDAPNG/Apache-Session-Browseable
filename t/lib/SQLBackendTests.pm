package SQLBackendTests;

# Common tests for SQL backends, run only if <env>_DSN is set (credentials
# are read from <env>_USER and <env>_PASSWORD). Parameters:
#  - class:   Apache::Session::Browseable class to test
#  - driver:  DBD driver name (Pg, mysql)
#  - env:     environment variables prefix (PG, MYSQL)
#  - table:   table name (dropped before and after tests)
#  - create:  SQL statements to create table (__TABLE__ is replaced)
#  - index:   indexed fields (DBI based backends, one column per field)
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
    $table =~ s/^asb_test_/$ENV{ASB_TEST_TABLE_PREFIX}/
      if $ENV{ASB_TEST_TABLE_PREFIX};

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
    my %todo = %{ $o{todo} || {} };

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
        },
        rtyler => {
            uid           => 'rtyler',
            _whatToTrace  => 'rtyler',
            _session_kind => 'Persistent',
            _utime        => 100,
            _lastSeen     => 300,
            mail          => 'rtyler@badwolf.org',
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

    # Non-ASCII values, in Latin-1 range and beyond
    foreach my $v ( "\x{c9}lodie", "\x{c9}lodie \x{3a9}" ) {
        ( my $l = $v ) =~ s/[^ -~]/?/g;
        my $u8 = $newSession->( uid => 'u8', cn => $v, list => [$v] );
        my $check = sub {
            my ($step) = @_;
            tie %session, $class, $u8, $args;
            is( $session{cn}, $v, "Value $l$step retrieved" );
            is_deeply( $session{list}, [$v], "Array with $l$step retrieved" );
            untie %session;
            my $r = $class->get_key_from_all_sessions($args);
            is( $r->{$u8}->{cn}, $v, "get_key_from_all_sessions returns $l$step" );
            $r = $class->get_key_from_all_sessions( $args, sub { $_[0]->{cn} } );
            is( $r->{$u8}, $v, "get_key_from_all_sessions with a code ref: $l$step" );
            $r = $class->get_key_from_all_sessions( $args, ['cn'] );
            is( $r->{$u8}->{cn}, $v, "get_key_from_all_sessions with fields: $l$step" );
            $r = $class->searchOn( $args, 'uid', 'u8' );
            is( $r->{$u8}->{cn}, $v, "searchOn without fields returns $l$step" );
            $r = $class->searchOn( $args, 'uid', 'u8', 'cn' );
            is( $r->{$u8}->{cn}, $v, "searchOn with fields returns $l$step" );
        };
        $check->('');

        # Update the session: the store rewrites the non-ASCII values
        tie %session, $class, $u8, $args;
        $session{x} = 1;
        untie %session;
        $check->(' after update');
        $dbh->do( "DELETE FROM $table WHERE id=?", undef, $u8 );
    }

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

    $dbh->do("DROP TABLE IF EXISTS $table");
    $dbh->disconnect;
    done_testing();
}

1;
