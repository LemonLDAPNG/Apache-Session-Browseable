package Apache::Session::Browseable::Sybase;

use strict;

use Apache::Session;
use Apache::Session::Lock::Null;
use Apache::Session::Browseable::Store::Sybase;
use Apache::Session::Generate::SHA256;
use Apache::Session::Serialize::Sybase;
use Apache::Session::Browseable::DBI;

our $VERSION = '1.2.2';
our @ISA     = qw(Apache::Session::Browseable::DBI Apache::Session);

*serialize   = \&Apache::Session::Serialize::Sybase::serialize;
*unserialize = \&Apache::Session::Serialize::Sybase::unserialize;

sub populate {
    my $self = shift;

    $self->{object_store} =
      new Apache::Session::Browseable::Store::Sybase $self;
    $self->{lock_manager} = new Apache::Session::Lock::Null $self;
    $self->{generate}     = \&Apache::Session::Generate::SHA256::generate;
    $self->{validate}     = \&Apache::Session::Generate::SHA256::validate;
    $self->{serialize}    = \&Apache::Session::Serialize::Sybase::serialize;
    $self->{unserialize}  = \&Apache::Session::Serialize::Sybase::unserialize;

    return $self;
}

1;
__END__

=head1 NAME

Apache::Session::Browseable::Sybase - Add index and search methods to
Apache::Session for Sybase databases

=head1 DESCRIPTION

Create a table with a column for each field listed in C<Index> and use it like
L<Apache::Session::Browseable::Postgres>.

=head2 searchLt() and searchGt()

searchLt() and searchGt() take the same arguments and return the same data as
searchOn(): sessions whose field is lower (or greater) than the given value,
which is excluded. The value must be a number (C<12>, C<-12> or C<12.5>):
otherwise nothing is returned and an error is printed on STDERR. Spaces
around the value are ignored.

Fields listed in C<Index> are compared in SQL as integers
(C<cast(field as integer)>), other fields in Perl after reading all sessions.
Depending on the database, the cast rounds or truncates values that are not
integers, or fails on non-numeric ones, whereas Perl compares their numeric
value: store integers in indexed fields.

Sessions without the field are never returned, whereas the Perl fallback of
Lemonldap::NG compares a missing field as 0.

=head1 SEE ALSO

L<Apache::Session::Browseable>, L<Apache::Session::Browseable::Postgres>

=cut
