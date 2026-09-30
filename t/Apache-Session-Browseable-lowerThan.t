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
}
my $dbh = FakeDbh->new;

# The database handle is optional: MySQLJSON needs it to quote the JSON path,
# but the DBI deleteIfLowerThan() path doesn't provide one
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
);

foreach (@tests) {
    my ( $backend, $field, $expected ) = @$_;
    my $class = "Apache::Session::Browseable::$backend";
  SKIP: {
        skip "$class can't be loaded", 1 unless ( eval "require $class" );
        is( $class->_buildLowerThanExpression( $field, 200, $dbh ),
            $expected, "$backend: $field" );
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

done_testing();
