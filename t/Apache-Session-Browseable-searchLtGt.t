use strict;
use Test::More;

# searchLt() and searchGt() without database: SQL queries sent by each
# backend, fields compared in Perl
{

    package FakeDbh;
    sub new { bless {}, shift }

    sub quote {
        my ( $self, $s ) = @_;
        $s =~ s/'/''/g;
        return "'$s'";
    }

    # MariaDBJSON checks that Index columns are generated from a_session: all
    # the tested ones are
    sub prepare { return bless {}, 'FakeSth' }

    package FakeSth;

    # Arguments: table name, then the Index fields
    sub execute {
        my ( $self, $table, @fields ) = @_;
        $self->{fields} = \@fields;
        return 1;
    }

    sub fetchall_arrayref {
        return [ map { [ $_, "JSON_VALUE(a_session, '\$.$_')" ] }
              @{ $_[0]->{fields} } ];
    }
    sub finish { return 1 }
}

my $t     = 1700000000;
my $index = { Index => '_utime _oidcRtUpdate' };
my @tests = (
    [ 'PgJSON',    q{cast(a_session ->> '_oidcRtUpdate' as bigint)} ],
    [ 'Patroni',   q{cast(a_session ->> '_oidcRtUpdate' as bigint)} ],
    [ 'PgHstore',  q{cast(a_session -> '_oidcRtUpdate' as bigint)} ],
    [ 'MySQLJSON', q{cast(a_session->>'$._oidcRtUpdate' as UNSIGNED)} ],
    [
        'MariaDBJSON',
        q{cast(JSON_VALUE(a_session, '$._oidcRtUpdate') as UNSIGNED)}
    ],
    [ 'MariaDBJSON', '`_oidcRtUpdate`',                $index ],
    [ 'Postgres',    'cast(_oidcRtUpdate as bigint)',  $index ],
    [ 'MySQL',       '_oidcRtUpdate',                  $index ],
    [ 'SQLite',      'cast(_oidcRtUpdate as integer)', $index ],
    [ 'Oracle',      'cast(_oidcRtUpdate as integer)', $index ],
    [ 'Informix',    'cast(_oidcRtUpdate as integer)', $index ],
    [ 'Sybase',      'cast(_oidcRtUpdate as integer)', $index ],
);

# Sessions returned by the mocked get_key_from_all_sessions()
my %sessions = (
    s1 => { _oidcRtUpdate => 100,   uid => 'a' },
    s2 => { _oidcRtUpdate => 200,   uid => 'b' },
    s3 => { _oidcRtUpdate => 'abc', uid => 'c' },
    s4 => { uid           => 'd' },
);

foreach (@tests) {
    my ( $backend, $expr, $args ) = @$_;
    $args ||= {};
    my $class = "Apache::Session::Browseable::$backend";
    my $desc  = $backend . ( $args->{Index} ? ' (indexed)' : '' );
  SKIP: {
        skip "$class can't be loaded", 12 unless ( eval "require $class" );
        my ( @queries, $scans );
        no strict 'refs';
        no warnings 'redefine';
        local *{"${class}::_classDbh"} = sub { FakeDbh->new };
        local *{"${class}::_query"}    = sub {
            my ( $c, @a ) = @_;
            shift @a
              while ( @a and !( ref( $a[0] ) eq 'HASH' and $a[0]->{query} ) );
            push @queries,
              [ $a[0]->{query}, @{ $a[0]->{values} }, '|', @a[ 1 .. $#a ] ];
            return {};
        };
        local *{"${class}::get_key_from_all_sessions"} = sub { $scans++; {} };

        foreach ( [ searchLt => '<' ], [ searchGt => '>' ] ) {
            my ( $m, $op ) = @$_;
            @queries = ();
            my $res = $class->$m( $args, '_oidcRtUpdate', $t, 'uid' );
            is_deeply( $res, {}, "$desc: $m returns query result" );
            is_deeply(
                \@queries,
                [ [ "$expr $op $t", '|', 'uid' ] ],
                "$desc: $m query"
            );
        }

        # Surrounding spaces are removed (the Lemonldap::NG CLI keeps them)
        @queries = ();
        $class->searchGt( $args, '_oidcRtUpdate', " $t \n" );
        is_deeply(
            \@queries,
            [ [ "$expr > $t", '|' ] ],
            "$desc: spaces around value removed"
        );

        # Values are checked before being inserted in queries
        @queries = ();
        foreach my $bad ( "$t OR 1=1", '1e3', '', ' ', undef ) {
            local *STDERR;
            open STDERR, '>', \my $err;
            is_deeply( $class->searchLt( $args, '_oidcRtUpdate', $bad ),
                {}, "$desc: bad value returns nothing" );
        }
        is_deeply( \@queries, [], "$desc: bad values: no query" );
        ok( !$scans, "$desc: sessions not read" );
    }
}

# Column backends: fields not listed in Index are compared in Perl (always
# with Cassandra: CQL can't compare them). Sessions without the field are
# skipped; "abc" is 0 as in Perl
foreach my $backend (qw(Postgres MySQL SQLite Cassandra)) {
    my $class = "Apache::Session::Browseable::$backend";
    my $args  = $backend eq 'Cassandra' ? $index : {};
  SKIP: {
        skip "$class can't be loaded", 4 unless ( eval "require $class" );
        my $queries = 0;
        no strict 'refs';
        no warnings 'redefine';
        local *{"${class}::_query"}                    = sub { $queries++; {} };
        local *{"${class}::get_key_from_all_sessions"} = sub {
            my ( $c, $args, $sub ) = @_;
            $sub->( $sessions{$_}, $_ ) foreach ( sort keys %sessions );
            return {};
        };
        my $res = $class->searchLt( $args, '_oidcRtUpdate', 150 );
        is_deeply( [ sort keys %$res ],
            [qw(s1 s3)], "$backend: searchLt in Perl" );
        is_deeply( $res->{s1}, $sessions{s1}, "$backend: whole session" );
        $res = $class->searchGt( $args, '_oidcRtUpdate', -1, 'uid' );
        is_deeply(
            $res,
            {
                s1 => { uid => 'a' },
                s2 => { uid => 'b' },
                s3 => { uid => 'c' }
            },
            "$backend: searchGt in Perl, with fields"
        );
        is( $queries, 0, "$backend: no SQL comparison" );
    }
}

# Cassandra: as the other backends, a non numeric value returns nothing and
# prints an error instead of being compared as 0
SKIP: {
    my $class = 'Apache::Session::Browseable::Cassandra';
    skip "$class can't be loaded", 6 unless ( eval "require $class" );
    no strict 'refs';
    no warnings 'redefine';
    foreach my $m (qw(searchLt searchGt)) {
        my $scans = 0;
        local *{"${class}::get_key_from_all_sessions"} = sub { $scans++; {} };
        local *STDERR;
        open STDERR, '>', \my $err;
        my $res = $class->$m( $index, '_oidcRtUpdate', 'abc' );
        is_deeply( $res, {},
            "Cassandra: $m with a non numeric value returns nothing" );
        like( $err, qr/value must be a number/,
            "Cassandra: $m with a non numeric value prints an error" );
        is( $scans, 0, "Cassandra: $m with a non numeric value reads nothing" );
    }
}

# _buildCompareExpression() only accepts the operators it knows, in each
# backend
foreach my $backend ( 'Postgres', 'PgJSON', 'PgHstore', 'MySQL', 'MySQLJSON',
    'MariaDBJSON', 'SQLite', 'Oracle', 'Informix', 'Sybase', 'Patroni' )
{
    my $class = "Apache::Session::Browseable::$backend";
  SKIP: {
        skip "$class can't be loaded", 4 unless ( eval "require $class" );
        foreach my $op ( '; DROP TABLE x', '<=', '', undef ) {
            eval {
                $class->_buildCompareExpression( '_utime', $op, 1,
                    FakeDbh->new, {} );
            };
            like( $@, qr/invalid operator/,
                "$backend: _buildCompareExpression rejects "
                  . ( defined $op ? "'$op'" : 'undef' ) );
        }
    }
}

# No public fallback in _common.pm: File keeps the Lemonldap::NG one
SKIP: {
    my $class = 'Apache::Session::Browseable::File';
    skip "$class can't be loaded", 2 unless ( eval "require $class" );
    ok( !$class->can('searchLt'), 'File: no searchLt' );
    ok( !$class->can('searchGt'), 'File: no searchGt' );
}

done_testing();
