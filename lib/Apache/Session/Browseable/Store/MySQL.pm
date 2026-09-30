package Apache::Session::Browseable::Store::MySQL;

use strict;

use Apache::Session::Browseable::Store::DBI;
use Apache::Session::Store::MySQL;

our @ISA =
  qw(Apache::Session::Browseable::Store::DBI Apache::Session::Store::MySQL);
our $VERSION = '1.2.2';

sub connection {
    my ( $self, $session ) = @_;

    # AutoCommit on: see "Why AutoCommit differs" in Store/DBI.pm
    $self->_connection( $session, 'Apache::Session::Store::MySQL',
        { RaiseError => 1, AutoCommit => 1 } );
    if ( $self->{dbh}->{Driver}->{Name} eq "mysql" ) {
        $self->{dbh}->{mysql_enable_utf8} = 1;
    }
}

1;

