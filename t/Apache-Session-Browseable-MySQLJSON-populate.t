use strict;
use Test::More;

# MySQLJSON refuses Index: the store would write indexed fields into columns
# that don't exist in a JSON table
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
        my $err = eval { $self->populate; '' } || $@;
        like( $err, qr/Index must not be set/, 'MySQLJSON refuses Index' );
    }
}

done_testing();
