package Apache::Session::Browseable::Store::Sybase;

use strict;

use Apache::Session::Browseable::Store::DBI;
use Apache::Session::Store::Sybase;

our @ISA =
  qw(Apache::Session::Browseable::Store::DBI Apache::Session::Store::Sybase);
our $VERSION = '1.2.2';

sub connection {
    my ( $self, $session ) = @_;

    # AutoCommit off: see "Why AutoCommit differs" in Store/DBI.pm
    $self->_connection( $session, 'Apache::Session::Store::Sybase',
        { RaiseError => 1, AutoCommit => 0 } );
}

1;

