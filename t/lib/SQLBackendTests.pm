package SQLBackendTests;

# Common tests for SQL backends, run only if <env>_DSN is set (credentials
# are read from <env>_USER and <env>_PASSWORD). Parameters:
#  - class:   Apache::Session::Browseable class to test
#  - driver:  DBD driver name (Pg, mysql)
#  - env:     environment variables prefix (PG, MYSQL)
#  - table:   table name (dropped before and after tests)
#  - create:  SQL statements to create table (__TABLE__ is replaced)
#  - index:   indexed fields (DBI based backends, one column per field)
#  - gin:     1 to compare searchOn() results with and without GinIndex
#  - todo:    known bugs of this backend: { test group => reason }. Tests of
#             these groups are run as TODO tests and may die without
#             breaking the rest of the suite

use strict;
use warnings;
use Test::More;
use Exporter 'import';
use JSON;

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

    # GinIndex: searchOn() must return the same results with jsonb
    # containment, whatever the JSON type of the searched field
    if ( $o{gin} ) {
        $dbh->do("DELETE FROM $table");

        # Force the GIN index to be used, even on this small table
        my $mdbh = $class->_classDbh($args);
        $mdbh->do('SET enable_seqscan = off');
        my $pi   = '3.14159265358979323846264338327950288419716939937510';
        my $big  = '1' . ( '0' x 131071 );
        my %rows = (
            num      => '{"k":123}',
            str      => '{"k":"123"}',
            dec      => '{"k":1.50}',
            dec2     => '{"k":1.5}',
            negzero  => '{"k":-0}',
            exp      => '{"k":1e2}',
            exp2     => '{"k":1E+2}',
            zero5    => '{"k":0e5}',
            dec4     => '{"k":123.0000}',
            pi       => qq({"k":$pi}),
            big      => qq({"k":$big}),
            true     => '{"k":true}',
            strtrue  => '{"k":"true"}',
            false    => '{"k":false}',
            array    => '{"k":[1,2]}',
            strarray => '{"k":"[1, 2]"}',
            object   => '{"k":{"a":1}}',
            null     => '{"k":null}',
            strnull  => '{"k":"null"}',
            empty    => '{"k":""}',
            other    => '{"j":"123"}',
            quotes   => JSON->new->encode( { k => qq{O'B"r\\n} } ),
            newline  => JSON->new->encode( { k => "x\ny" } ),
            unicode  => JSON->new->ascii->encode( { k => "\x{e9}t\x{e9}" } ),
            smiley   => JSON->new->encode( { k => "\x{263a}" } ),
        );
        $dbh->do( "INSERT INTO $table (id,a_session) VALUES (?,?)",
            undef, $_, $rows{$_} )
          foreach ( keys %rows );
        my $gargs = { %$args, GinIndex => 1 };

        foreach my $v ( 'dwho', '1.5' ) {
            my $q    = $class->_searchOnQuery( $gargs, 'k', $v );
            my $plan = join "\n",
              map { $_->[0] } @{
                $mdbh->selectall_arrayref(
                    "EXPLAIN SELECT id FROM $table WHERE $q->{query}",
                    undef, @{ $q->{values} } )
              };
            like(
                $plan,
                qr/Bitmap Index Scan on \w+_gin/,
                "GinIndex query for '$v' uses the GIN index"
            );
        }

        foreach (
            [ '123',                  'num,str' ],
            [ 123,                    'num,str' ],
            [ '1.5',                  'dec2' ],
            [ '1.50',                 'dec' ],
            [ '123.0000',             'dec4' ],
            [ '123.0',                '' ],
            [ '0',                    'negzero,zero5' ],
            [ '-0',                   '' ],
            [ '0e5',                  '' ],
            [ '100',                  'exp,exp2' ],
            [ '1e2',                  '' ],
            [ '1E+2',                 '' ],
            [ $pi,                    'pi' ],
            [ substr( $pi, 0, 20 ),   '' ],
            [ $big,                   'big' ],
            [ $big . '0',             '' ],
            [ '0.' . ( '1' x 16384 ), '' ],
            [ 'true',                 'strtrue,true' ],
            [ 'false',                'false' ],
            [ '[1, 2]',               'array,strarray' ],
            [ '{"a": 1}',             'object' ],
            [ 'null',                 'strnull' ],
            [ '',                     'empty' ],
            [ qq{O'B"r\\n},           'quotes' ],
            [ "x\ny",                 'newline' ],
            [ "\x{e9}t\x{e9}",        'unicode' ],
            [ "\x{263a}",             'smiley' ],
            [ 'none',                 '' ],
          )
        {
            my ( $v, $expected ) = @$_;
            ( my $l = $v ) =~ s/[^ -~]/?/g;
            $l = substr( $l, 0, 20 ) . '...(' . length($l) . ')'
              if ( length($l) > 30 );
            my $off = $class->searchOn( $args, 'k', $v, 'k' );
            is( $name->($off), $expected, "searchOn [$l] on JSON types" );
            my $on = eval { $class->searchOn( $gargs, 'k', $v, 'k' ) };
            diag $@ if $@;
            is_deeply( $on, $off, "searchOn [$l] with GinIndex: same result" );
        }
        is_deeply(
            $class->searchOn( $gargs, 'k', '123' ),
            $class->searchOn( $args,  'k', '123' ),
            'searchOn with GinIndex without fields: same result'
        );

        $reset->();
        foreach my $w ( "weird'field", 'uid', '_utime' ) {
            my $v   = $w eq 'uid' ? "O'Brien" : $w eq '_utime' ? 100 : 'w1';
            my $off = $class->searchOn( $args, $w, $v, 'uid' );
            is_deeply( $class->searchOn( $gargs, $w, $v, 'uid' ),
                $off, "searchOn on field [$w] with GinIndex: same result" );
        }
        $mdbh->do('RESET enable_seqscan');
    }

    $dbh->do("DROP TABLE IF EXISTS $table");
    $dbh->disconnect;
    done_testing();
}

1;
