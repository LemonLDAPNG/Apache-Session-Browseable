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

my $args = { Index => 'uid', TableName => 'sessions' };

# A generated column based on a_session is accepted, and the check is done
# only once per handle and table
my $dbh =
  FakeDbh->new( rows => [ [ 'uid', "JSON_VALUE(a_session, '\$.uid')" ] ] );
eval { $class->_checkIndex( $dbh, $args ) };
is( $@, '', 'generated column accepted' );
is( $dbh->{prepares}, 1, 'one information_schema query' );
eval { $class->_checkIndex( $dbh, $args ) };
is( $dbh->{prepares}, 1, 'result is memoized' );
ok( $dbh->{private_asb_mariadbjson_index},
    'memoized on a DBI private attribute' );

# A column that exists but is not generated (migration from Browseable::MySQL)
# must fail instead of silently returning nothing
my $plain = FakeDbh->new( rows => [ [ 'uid', undef ] ] );
my $err = '';
eval { $class->_checkIndex( $plain, $args ) } or $err = $@;
like( $err, qr/Index field "uid"/, 'plain column rejected' );
like( $err, qr/not generated from a_session/, 'reason given' );

# A missing column must fail too
my $missing = FakeDbh->new( rows => [] );
$err = '';
eval { $class->_checkIndex( $missing, $args ) } or $err = $@;
like( $err, qr/Index field "uid"/, 'missing column rejected' );
like( $err, qr/no column with this name/, 'reason given' );

# A column generated from something else than a_session is rejected
my $other = FakeDbh->new( rows => [ [ 'uid', 'id' ] ] );
$err = '';
eval { $class->_checkIndex( $other, $args ) } or $err = $@;
like( $err, qr/not generated from a_session/, 'foreign expression rejected' );

# Everything listed in Index is checked, in one query
my $multi = FakeDbh->new(
    rows => [
        [ 'uid',      "JSON_VALUE(a_session, '\$.uid')" ],
        [ 'lastSeen', undef ],
    ]
);
$err = '';
eval {
    $class->_checkIndex( $multi,
        { Index => 'uid lastSeen', TableName => 's' } );
}
  or $err = $@;
like( $err, qr/Index field "lastSeen"/, 'every Index field is checked' );

done_testing();
