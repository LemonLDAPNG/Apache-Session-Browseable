package Apache::Session::Browseable::Store::Informix;

use strict;

use Apache::Session::Browseable::Store::DBI;
use Apache::Session::Store::Informix;

our @ISA =
  qw(Apache::Session::Browseable::Store::DBI Apache::Session::Store::Informix);
our $VERSION = '1.2.2';

sub connection {
    my ( $self, $session ) = @_;

    # AutoCommit off: see "Why AutoCommit differs" in Store/DBI.pm
    $self->_connection( $session, 'Apache::Session::Store::Informix',
        { RaiseError => 1, AutoCommit => 0 } );
}

1;

