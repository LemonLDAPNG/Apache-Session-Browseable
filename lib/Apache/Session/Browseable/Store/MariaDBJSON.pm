package Apache::Session::Browseable::Store::MariaDBJSON;

use strict;

use Apache::Session::Store::MySQL;

# Only id and a_session are written: indexed fields are generated columns
our @ISA     = qw(Apache::Session::Store::MySQL);
our $VERSION = '1.3.20';

sub connection {
    my ( $self, $session ) = @_;
    $self->SUPER::connection($session);

    # DBD::MariaDB always uses UTF-8
    if ( $self->{dbh}->{Driver}->{Name} eq 'mysql' ) {
        $self->{dbh}->{mysql_enable_utf8} = 1;
    }
}

1;
