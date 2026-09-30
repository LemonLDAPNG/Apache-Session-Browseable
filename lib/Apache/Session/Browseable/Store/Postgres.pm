package Apache::Session::Browseable::Store::Postgres;

use strict;

use Apache::Session::Browseable::Store::DBI;
use Apache::Session::Store::Postgres;

our @ISA =
  qw(Apache::Session::Browseable::Store::DBI Apache::Session::Store::Postgres);
our $VERSION = '1.2.2';

sub connection {
    my ( $self, $session ) = @_;
    $self->_connection( $session, 'Apache::Session::Store::Postgres',
        { RaiseError => 1, AutoCommit => 0 } );
    $self->{dbh}->{pg_enable_utf8} = 1;
}

1;

