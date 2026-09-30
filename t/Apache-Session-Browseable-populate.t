use strict;
use Test::More;

# Every SQL backend must reference existing serialize/unserialize subs
foreach my $backend (qw(Informix MySQL MySQLJSON Oracle PgHstore PgJSON
    Postgres SQLite Sybase))
{
    my $class = "Apache::Session::Browseable::$backend";
  SKIP: {
        skip "$class can't be loaded", 2 unless ( eval "require $class" );
        my $self = do { no strict 'refs'; &{"${class}::populate"}() };
        ok( defined &{ $self->{serialize} },   "$backend serialize sub exists" );
        ok( defined &{ $self->{unserialize} }, "$backend unserialize sub exists" );
    }
}

# MySQLJSON warns about Index: the store would write indexed fields into
# columns that don't exist in a JSON table
SKIP: {
    my $class = 'Apache::Session::Browseable::MySQLJSON';
    skip "$class can't be loaded", 5 unless ( eval "require $class" );
    foreach my $index ( undef, '', '  ' ) {
        my $self = bless { args => {} }, $class;
        $self->{args}->{Index} = $index if defined $index;
        my $ok = eval { $self->populate; 1 };
        ok( $ok, 'MySQLJSON accepts a missing or empty Index' ) or diag $@;
    }
    foreach my $index ( 'uid', [ 'uid', 'mail' ] ) {
        my $self = bless { args => {} }, $class;
        $self->{args}->{Index} = $index;
        my @warn;
        local $SIG{__WARN__} = sub { push @warn, @_ };
        eval { $self->populate };
        like( join( '', @warn ), qr/Index should not be set/,
            'MySQLJSON warns about Index' );
    }
}

done_testing();
