use strict;
use Test::More;

# deleteIfLowerThan() expressions must stay identical to the documented
# indexes, else databases can't use them
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
    sub execute { return 1 }
    sub fetchall_arrayref {
        return [
            [ '_utime',    "JSON_VALUE(a_session, '\$._utime')" ],
            [ '_lastSeen', "JSON_VALUE(a_session, '\$._lastSeen')" ],
        ];
    }
    sub finish { return 1 }
}
my $dbh = FakeDbh->new;

# The database handle is optional: MySQLJSON and MariaDBJSON need it to quote
# the JSON path, but the DBI deleteIfLowerThan() path doesn't provide one.
# Connection arguments (Index) are only used by MariaDBJSON
my $index = { Index => '_utime _lastSeen' };
my @tests = (
    [ 'Postgres', '_utime', 'cast(_utime as bigint) < 200' ],
    [ 'MySQL',    '_utime', '_utime < 200' ],
    [ 'PgJSON',   '_utime', q{cast(a_session ->> '_utime' as bigint) < 200} ],
    [
        'PgJSON', '_lastSeen',
        q{cast(a_session ->> '_lastSeen' as bigint) < 200}
    ],
    [ 'Patroni',  '_utime', q{cast(a_session ->> '_utime' as bigint) < 200} ],
    [ 'PgHstore', '_utime', q{cast(a_session -> '_utime' as bigint) < 200} ],
    [
        'PgHstore', '_lastSeen',
        q{cast(a_session -> '_lastSeen' as bigint) < 200}
    ],
    [
        'MySQLJSON', '_utime',
        q{cast(a_session->>'$._utime' as UNSIGNED) < 200}
    ],
    [
        'MySQLJSON', '_lastSeen',
        q{cast(a_session->>'$._lastSeen' as UNSIGNED) < 200}
    ],
    [
        'MariaDBJSON', '_utime',
        q{cast(JSON_VALUE(a_session, '$._utime') as UNSIGNED) < 200}
    ],
    [ 'MariaDBJSON', '_utime',    '`_utime` < 200',    $index ],
    [ 'MariaDBJSON', '_lastSeen', '`_lastSeen` < 200', $index ],
);

foreach (@tests) {
    my ( $backend, $field, $expected, $args ) = @$_;
    my $class = "Apache::Session::Browseable::$backend";
  SKIP: {
        skip "$class can't be loaded", 1 unless ( eval "require $class" );
        is( $class->_buildLowerThanExpression( $field, 200, $dbh, $args ),
            $expected, "$backend: $field" . ( $args ? ' (indexed)' : '' ) );
    }
}

# MySQLJSON must build the same expression without a database handle
foreach (@tests) {
    my ( $backend, $field, $expected ) = @$_;
    next unless ( $backend eq 'MySQLJSON' );
    my $class = "Apache::Session::Browseable::$backend";
  SKIP: {
        skip "$class can't be loaded", 1 unless ( eval "require $class" );
        is( $class->_buildLowerThanExpression( $field, 200 ),
            $expected, "$backend: $field without database handle" );
    }
}

# _utf8() must convert both UTF-8 and Latin-1 byte strings (searched values or
# field names read without decoding) to the same character
foreach my $backend (qw(MySQLJSON MariaDBJSON)) {
    my $class = "Apache::Session::Browseable::$backend";
  SKIP: {
        skip "$class can't be loaded", 2 unless ( eval "require $class" );
        my ($utf8)   = $class->_utf8("\xc3\xa9");
        my ($latin1) = $class->_utf8("\xe9");
        is( $utf8,   "\x{e9}", "$backend: _utf8 decodes UTF-8 bytes" );
        is( $latin1, "\x{e9}", "$backend: _utf8 keeps Latin-1 bytes" );
    }
}

done_testing();
