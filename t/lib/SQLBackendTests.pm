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
#  - null:    1 if a field can be stored as JSON null (JSON backends)
#  - exact:   1 to check that searches are case and accent sensitive
#  - scs:     1 to also test with standard_conforming_strings=off (PostgreSQL)
#  - corrupt: a_session value that can't be unserialized
#  - explain: sub( $class, $dbh ) returning a list of
#             [ description, WHERE clause, index or array ref of indexes ]:
#             the plan of each WHERE clause must use all these indexes
#
# ASB_TEST_TABLE_PREFIX environment variable replaces the "asb_test_" prefix
# of table names.

use strict;
use warnings;
use Test::More;
use Exporter 'import';

our @EXPORT = qw(run_tests);

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
        my %rev = reverse %$ids;
        return join ',', sort map { $rev{$_} // $_ } keys %{ $_[0] };
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

    # Store / retrieve
    my $id = $newSession->( %{ $data{dwho} }, list => [ 1, 2 ] );
    ok( $id, 'Session created' );
    my %session;
    ok( tie( %session, $class, $id, $args ), 'Session retrieved' );
    is( $session{$_}, $data{dwho}->{$_}, "Field $_ retrieved" )
      foreach ( sort keys %{ $data{dwho} } );
    is_deeply( $session{list}, [ 1, 2 ], 'Array retrieved' );
    untie %session;

    $reset->();

    # searchOn
    my $res = $class->searchOn( $args, 'uid', 'dwho' );
    is( $name->($res), 'dwho', 'searchOn without fields' );
    is( $res->{ $ids->{dwho} }->{mail},
        'dwho@badwolf.org', 'searchOn without fields returns session data' );

    $res = $class->searchOn( $args, 'uid', 'dwho', '_whatToTrace', 'uid' );
    is_deeply(
        $res,
        {
            $ids->{dwho} =>
              { id => $ids->{dwho}, _whatToTrace => 'dwho', uid => 'dwho' }
        },
        'searchOn with fields keeps field name case'
    );

    $res = $class->searchOn( $args, '_whatToTrace', "O'Brien", 'uid' );
    is_deeply(
        $res,
        { $ids->{obrien} => { id => $ids->{obrien}, uid => "O'Brien" } },
        'searchOn on a value containing a quote'
    );

    $res = $class->searchOn( $args, '_session_kind', 'SSO', '_utime' );
    is( $name->($res), 'dwho,obrien', 'searchOn on _session_kind' );

    # searchOnExpr
    $res = $class->searchOnExpr( $args, 'uid', "O'Br*" );
    is( $name->($res), 'obrien', 'searchOnExpr on a value containing a quote' );
    is( $res->{ $ids->{obrien} }->{mail},
        'obrien@badwolf.org',
        'searchOnExpr without fields returns session data' );

    $res = $class->searchOnExpr( $args, '_whatToTrace', '*t*', '_whatToTrace' );
    is_deeply(
        $res,
        {
            $ids->{rtyler} => { id => $ids->{rtyler}, _whatToTrace => 'rtyler' }
        },
        'searchOnExpr with fields'
    );

    # Case and accent sensitive searches, on indexed and non indexed fields
    if ( $o{exact} ) {
        # Character string: DBD::mysql sends other strings in Latin-1, which
        # an utf8mb4 column rejects
        my $elodie = "\x{c9}lodie";
        utf8::upgrade($elodie);
        my $uid = $newSession->(
            %{ $data{dwho} },
            uid          => $elodie,
            _whatToTrace => $elodie,
        );
        foreach my $f (qw(_whatToTrace uid)) {
            $res = $class->searchOn( $args, $f, 'DWHO' );
            is_deeply( $res, {}, "searchOn on $f is case sensitive" );
            $res = $class->searchOnExpr( $args, $f, 'DW*' );
            is_deeply( $res, {}, "searchOnExpr on $f is case sensitive" );
            foreach my $v (qw(elodie ELODIE)) {
                $res = $class->searchOn( $args, $f, $v );
                is_deeply( $res, {}, "searchOn on $f: $v doesn't match" );
                $res = $class->searchOnExpr( $args, $f, "$v*" );
                is_deeply( $res, {}, "searchOnExpr on $f: $v* doesn't match" );
            }

            $res = $class->searchOn( $args, $f, $elodie );
            is( $name->($res), $uid, "searchOn on $f: exact value found" );
        }
        $dbh->do( "DELETE FROM $table WHERE id=?", undef, $uid );
    }

    # get_key_from_all_sessions
    $res = $class->get_key_from_all_sessions($args);
    is( $name->($res), 'dwho,nokind,obrien,rtyler',
        'get_key_from_all_sessions without argument' );
    is( $res->{ $ids->{rtyler} }->{mail},
        'rtyler@badwolf.org',
        'get_key_from_all_sessions returns session data' );

    $res = $class->get_key_from_all_sessions( $args, '_whatToTrace' );
    is_deeply(
        $res->{ $ids->{rtyler} },
        { id => $ids->{rtyler}, _whatToTrace => 'rtyler' },
        'get_key_from_all_sessions with a field name'
    );

    # Mixed-case field with a false value
    my $zero = $newSession->( %{ $data{dwho} }, _whatToTrace => '0' );
    $res = $class->searchOn( $args, 'uid', 'dwho', '_whatToTrace' );
    is( $res->{$zero}->{_whatToTrace},
        '0', 'searchOn with fields keeps false value under original case' );
    $res = $class->get_key_from_all_sessions( $args, ['_whatToTrace'] );
    is( $res->{$zero}->{_whatToTrace},
        '0', 'get_key_from_all_sessions with array ref and false value' );
    $res = $class->get_key_from_all_sessions( $args, '_whatToTrace' );
    is( $res->{$zero}->{_whatToTrace},
        '0', 'get_key_from_all_sessions with a field name and false value' );
    $dbh->do( "DELETE FROM $table WHERE id=?", undef, $zero );

    my $fields = [ 'uid', '_utime' ];
    $res = $class->get_key_from_all_sessions( $args, $fields );
    is( $name->($res), 'dwho,nokind,obrien,rtyler',
        'get_key_from_all_sessions with an array ref' );
    is( $res->{ $ids->{obrien} }->{uid},
        "O'Brien", 'get_key_from_all_sessions with an array ref returns data' );
    is_deeply( $fields, [ 'uid', '_utime' ], 'Array ref is not modified' );

    $res = $class->get_key_from_all_sessions( $args,
        sub { $_[0]->{uid} eq 'dwho' ? $_[0]->{mail} : undef } );
    is_deeply(
        $res,
        { $ids->{dwho} => 'dwho@badwolf.org' },
        'get_key_from_all_sessions with a code ref'
    );

    # get_key_from_all_sessions reads sessions by batches
    {
        local $Apache::Session::Browseable::_common::BatchSize = 2;
        my $queries = 0;
        my $cdbh    = $class->_classDbh($args);
        local $cdbh->{Callbacks} =
          { ChildCallbacks => { execute => sub { $queries++; return } } };
        foreach my $n ( 4, 5 ) {
            $newSession->( uid => 'extra' ) if ( $n == 5 );
            $queries = 0;
            my $calls = 0;
            $res = $class->get_key_from_all_sessions( $args,
                sub { $calls++; $_[1] } );
            is( $calls, $n,
                "$n sessions by batches: callback called for each" );
            is( scalar( keys %$res ),
                $n, "$n sessions by batches: all returned" );
            is( $queries, 3, "$n sessions by batches: 3 queries" );
        }
        $res = $class->get_key_from_all_sessions($args);
        is( scalar( keys %$res ), 5, 'Sessions by batches without callback' );
        $reset->();
    }

    # Fields needing quotes
    foreach my $w (@weird) {
        $res = $class->searchOn( $args, $w, 'w1', $w, 'uid' );
        is_deeply(
            $res,
            {
                $ids->{dwho} =>
                  { id => $ids->{dwho}, $w => 'w1', uid => 'dwho' }
            },
            "searchOn on field [$w]"
        );
        $res = $class->searchOnExpr( $args, $w, 'w*', 'uid' );
        is( $name->($res), 'dwho,rtyler', "searchOnExpr on field [$w]" );
        $res = $class->get_key_from_all_sessions( $args, [ $w, 'uid' ] );
        is( $res->{ $ids->{rtyler} }->{$w},
            'w2', "get_key_from_all_sessions with field [$w]" );
    }
    if ( $o{json} ) {
        foreach my $w ( "x' OR '1'='1", 'x" OR "1"="1', "x`y" ) {
            $res = eval { $class->searchOn( $args, $w, 'w1', $w ) };
            is_deeply( $res, {}, "searchOn on field [$w]: no injection" )
              or diag $@;
            $res = eval { $class->get_key_from_all_sessions( $args, [$w] ) };
            is( scalar( keys %$res ),
                4, "get_key_from_all_sessions with field [$w]" )
              or diag $@;
        }
    }

    # deleteIfLowerThan
    my @r = $class->deleteIfLowerThan( $args, { or => { _utime => 200 } } );
    is_deeply( \@r, [ 1, 3 ], 'deleteIfLowerThan "or": 3 sessions deleted' );
    is( $remaining->(), 'obrien', 'deleteIfLowerThan "or": 1 session kept' );

    $reset->();
    @r = $class->deleteIfLowerThan( $args,
        { or => { _utime => 200, _lastSeen => 200 } } );
    is_deeply( \@r, [ 1, 4 ], 'deleteIfLowerThan "or" with 2 fields' );

    $reset->();
    @r = $class->deleteIfLowerThan( $args,
        { and => { _utime => 200, _lastSeen => 200 } } );
    is_deeply( \@r, [ 1, 2 ], 'deleteIfLowerThan "and": 2 sessions deleted' );
    is( $remaining->(), 'obrien,rtyler', 'deleteIfLowerThan "and": 2 kept' );

    $reset->();
    @r = $class->deleteIfLowerThan( $args,
        { or => { _utime => 200 }, not => { _session_kind => 'Persistent' } } );
    is_deeply( \@r, [ 1, 2 ], 'deleteIfLowerThan "not": 2 sessions deleted' );
    is( $remaining->(), 'obrien,rtyler',
        'deleteIfLowerThan "not": session without field deleted' );

    $reset->();
    @r = $class->deleteIfLowerThan(
        $args,
        {
            and => { _utime        => 200, _lastSeen => 400 },
            not => { _session_kind => 'Persistent' }
        }
    );
    is_deeply( \@r, [ 1, 2 ], 'deleteIfLowerThan "and" with "not"' );
    is( $remaining->(), 'obrien,rtyler',
        'deleteIfLowerThan "and" with "not": right sessions kept' );

    $reset->();
    my $rule = { or => { _utime => 400 }, not => { uid => "O'Brien" } };
    @r = $class->deleteIfLowerThan( $args, $rule );
    is_deeply( \@r, [ 1, 3 ], 'deleteIfLowerThan "not" with a quote' );
    is( $remaining->(),      'obrien', 'deleteIfLowerThan "not" with a quote' );
    is( $rule->{not}->{uid}, "O'Brien", 'Rule is not modified' );

    $reset->();
    @r = $class->deleteIfLowerThan( $args,
        { or => { _utime => 400 }, not => { uid => "x' OR '1'='1" } } );
    is_deeply( \@r, [ 1, 4 ], 'deleteIfLowerThan "not": no injection' );

    $reset->();
    @r =
      eval { $class->deleteIfLowerThan( $args, { not => { uid => 'dwho' } } ); };
    is_deeply( \@r, [0], 'deleteIfLowerThan with only "not" returns 0' )
      or diag $@;
    foreach my $bad ( '200 OR 1=1', '1e3', '' ) {
        @r = $quiet->(
            sub {
                eval {
                    $class->deleteIfLowerThan( $args,
                        { or => { _utime => 400, _lastSeen => $bad } } );
                };
            }
        );
        is_deeply( \@r, [0],
            "deleteIfLowerThan with threshold '$bad' returns 0" );
    }
    is( $remaining->(), 'dwho,nokind,obrien,rtyler', 'Nothing deleted' );
    foreach my $bad ( '200 OR 1=1', '1e3', '', "\x{0661}" ) {
        ( my $label = $bad ) =~ s/[^ -~]/?/g;
        @r = $quiet->(
            sub {
                eval {
                    $class->deleteIfLowerThan( $args,
                        { and => { _utime => 400, _lastSeen => $bad } } );
                };
            }
        );
        is_deeply( \@r, [0],
            "deleteIfLowerThan \"and\" with threshold '$label' returns 0" );
    }
    is( $remaining->(), 'dwho,nokind,obrien,rtyler',
        'Nothing deleted with "and"' );

    @r = $class->deleteIfLowerThan( $args, { or => { _utime => '100.5' } } );
    is_deeply( \@r, [ 1, 3 ], 'deleteIfLowerThan with a decimal threshold' );

    foreach my $w (@weird) {
        $reset->();
        @r = $class->deleteIfLowerThan( $args,
            { or => { _utime => 400 }, not => { $w => 'w1' } } );
        is_deeply( \@r, [ 1, 3 ], "deleteIfLowerThan \"not\" on field [$w]" );
        is( $remaining->(), 'dwho', "deleteIfLowerThan \"not\" on field [$w]" );
    }

    # A field stored as JSON null does not protect a session
    if ( $o{null} ) {
        $reset->();
        my $nullId = $newSession->( %{ $data{dwho} }, _session_kind => undef );
        my $json =
          $dbh->selectrow_array( "SELECT a_session FROM $table WHERE id=?",
            undef, $nullId );
        like(
            $json,
            qr/"_session_kind"\s*:\s*null/,
            'Session with a JSON null field created'
        );
        @r = $class->deleteIfLowerThan( $args,
            { or => { _utime => 200 }, not => { _session_kind => 'SSO' } } );
        is_deeply( \@r, [ 1, 3 ],
            'deleteIfLowerThan "not": JSON null deleted' );
        is( $remaining->(), 'dwho,obrien',
            'deleteIfLowerThan "not": right sessions kept' );
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
            $res = eval { $class->searchOn( $args, $w, 'w1', 'uid' ) };
            diag $@ if $@;
            is( $name->( $res || {} ), $found ? 'dwho' : '', "searchOn on $l" );
            $res = eval { $class->searchOnExpr( $args, $w, 'w*', 'uid' ) };
            diag $@ if $@;
            is(
                $name->( $res || {} ),
                $found ? 'dwho,rtyler' : '',
                "searchOnExpr on $l"
            );
            $res = eval { $class->get_key_from_all_sessions( $args, [$w] ) };
            diag $@ if $@;
            is( scalar( keys %{ $res || {} } ),
                4, "get_key_from_all_sessions on $l" );
            is(
                ( $res || {} )->{ $ids->{rtyler} }->{$w},
                $found ? 'w2' : undef,
                "get_key_from_all_sessions returns the right value on $l"
            );
            @r = eval {
                $class->deleteIfLowerThan( $args,
                    { or => { _utime => 200 }, not => { $w => 'w1' } } );
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
        $mdbh->do('SET standard_conforming_strings = on');
        is( $mdbh->selectrow_array('SHOW standard_conforming_strings'),
            'on', 'standard_conforming_strings is back on' );
    }

    # Queries must be able to use indexes
    if ( $o{explain} ) {
        $reset->();
        $dbh->do('SET enable_seqscan = off') if ( $o{driver} eq 'Pg' );

        # MySQL >= 8.3: JSON and TREE formats have no possible_keys column
        eval { $dbh->do('SET SESSION explain_format=TRADITIONAL') }
          if ( $o{driver} eq 'mysql' );
        foreach ( $o{explain}->( $class, $dbh ) ) {
            my ( $desc, $where, $indexes ) = @$_;
            my @indexes =
              map { ( my $i = $_ ) =~ s/__TABLE__/$table/g; $i }
              ref($indexes) ? @$indexes : ($indexes);
            my $index = join ',', @indexes;
            my $sth =
              $dbh->prepare("EXPLAIN SELECT id FROM $table WHERE $where");
            $sth->execute;
            if ( $o{driver} eq 'Pg' ) {
                my $plan = join "\n",
                  map { $_->[0] } @{ $sth->fetchall_arrayref };
                my @missing = grep { $plan !~ /\b\Q$_\E\b/ } @indexes;
                ok( !@missing && $plan =~ /Index Cond/,
                    "$desc uses index $index" )
                  or diag "$where:\n$plan";
            }
            else {
                my $row     = $sth->fetchrow_hashref('NAME_lc');
                my $keys    = $row->{possible_keys} // '';
                my %keys    = map  { $_ => 1 } split /,/, $keys;
                my @missing = grep { !$keys{$_} } @indexes;
                ok( !@missing, "$desc can use index $index" )
                  or diag "$where: possible_keys=$keys";
                $sth->finish;
            }
        }
        $dbh->do('RESET enable_seqscan') if ( $o{driver} eq 'Pg' );
    }

    # Corrupted session must not break listing
    if ( $o{corrupt} ) {
        $reset->();
        $dbh->do( "INSERT INTO $table (id,a_session) VALUES ('corrupt',?)",
            undef, $o{corrupt} );
        $res = $quiet->( sub { $class->get_key_from_all_sessions($args) } );
        is( $name->($res), 'dwho,nokind,obrien,rtyler',
            'get_key_from_all_sessions skips corrupted session' );
    }

    $dbh->do("DROP TABLE IF EXISTS $table");
    $dbh->disconnect;
    done_testing();
}

1;
