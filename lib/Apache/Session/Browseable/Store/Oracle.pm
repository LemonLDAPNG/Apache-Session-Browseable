package Apache::Session::Browseable::Store::Oracle;

use strict;

use Apache::Session::Browseable::Store::DBI;
use Apache::Session::Store::Oracle;

our @ISA =
  qw(Apache::Session::Browseable::Store::DBI Apache::Session::Store::Oracle);
our $VERSION = '1.2.2';

# Oracle rejects unquoted identifiers starting with "_" (_whatToTrace,
# _utime...) and reserved words (uid): index columns are double-quoted, so
# their name is case sensitive. id and a_session stay unquoted. Oracle
# identifiers can't contain a double quote: it is doubled as in standard SQL,
# so that such a name makes the query fail instead of changing it
sub _quoteColumn {
    my ( $self, $field ) = @_;
    $field =~ s/"/""/g;
    return qq{"$field"};
}

# The materialize() of Apache::Session::Store::DBI comes first in @ISA: set
# LongReadLen as Apache::Session::Store::Oracle does, else sessions longer
# than 80 bytes can't be read
sub materialize {
    my ( $self, $session ) = @_;
    $self->connection($session);
    local $self->{dbh}->{LongReadLen} =
      $session->{args}->{LongReadLen} || 8 * 2**10;
    return $self->SUPER::materialize($session);
}

1;

