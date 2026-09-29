use strict;
use Test::More;

# _checkIndex() only needs a database handle to query information_schema: use a
# fake one, no server required
my $class = 'Apache::Session::Browseable::MariaDBJSON';
plan skip_all => "$class can't be loaded"
  unless ( eval "require $class" );

{
    package FakeDbh;
    sub new {
        my ( $class, %o ) = @_;
        return bless { rows => $o{rows} || [], prepares => 0 }, $class;
    }
    sub prepare {
        my ($self) = @_;
        $self->{prepares}++;
        return FakeSth->new($self);
    }

    package FakeSth;
    sub new {
        my ( $class, $dbh ) = @_;
        return bless { dbh => $dbh }, $class;
    }
    sub execute { return 1 }
    sub fetchall_arrayref {
        my ($self) = @_;
        return $self->{dbh}->{rows};
    }
    sub finish { return 1 }
}

# Returns the exception (if any) and the warnings
sub check {
    my @a = @_;
    my @warn;
    local $SIG{__WARN__} = sub { push @warn, @_ };
    my $ok = eval { $class->_checkIndex(@a); 1 };
    return ( $ok ? '' : $@, join( '', @warn ) );
}

my $args = { Index => 'uid', TableName => 'sessions' };

# A generated column based on a_session is accepted silently, and the check is
# done only once per handle and table
my $dbh =
  FakeDbh->new( rows => [ [ 'uid', "JSON_VALUE(a_session, '\$.uid')" ] ] );
my ( $err, $warn ) = check( $dbh, $args );
is( $err,  '', 'generated column accepted' );
is( $warn, '', 'no warning for a generated column' );
is( $dbh->{prepares}, 1, 'one information_schema query' );
check( $dbh, $args );
is( $dbh->{prepares}, 1, 'result is memoized' );
ok( $dbh->{private_asb_mariadbjson_index},
    'memoized on a DBI private attribute' );

# A column that exists but is not generated (migration from Browseable::MySQL)
# is reported instead of silently returning nothing
my $plain = FakeDbh->new( rows => [ [ 'uid', undef ] ] );
( $err, $warn ) = check( $plain, $args );
is( $err, '', 'plain column does not abort' );
like( $warn, qr/"uid".*not generated from a_session/s, 'reason given' );

# A missing column is reported too
my $missing = FakeDbh->new( rows => [] );
( $err, $warn ) = check( $missing, $args );
is( $err, '', 'missing column does not abort' );
like( $warn, qr/"uid".*no column with this name/s, 'reason given' );

# A column generated from something else than a_session is reported
my $other = FakeDbh->new( rows => [ [ 'uid', 'id' ] ] );
( $err, $warn ) = check( $other, $args );
like( $warn, qr/not generated from a_session/, 'foreign expression reported' );

# Everything listed in Index is checked, in one query
my $multi = FakeDbh->new(
    rows => [
        [ 'uid',      "JSON_VALUE(a_session, '\$.uid')" ],
        [ 'lastSeen', undef ],
    ]
);
( $err, $warn ) =
  check( $multi, { Index => 'uid lastSeen', TableName => 's' } );
like( $warn, qr/"lastSeen"/, 'every Index field is checked' );

done_testing();
