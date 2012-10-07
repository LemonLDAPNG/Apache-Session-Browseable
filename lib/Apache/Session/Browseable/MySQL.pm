package Apache::Session::Browseable::MySQL;

use strict;

use Apache::Session;
use Apache::Session::Lock::Null;
use Apache::Session::Browseable::Store::MySQL;
use Apache::Session::Generate::MD5;
use Apache::Session::Serialize::Storable;
use Apache::Session::Browseable::DBI;

our $VERSION = '0.4';
our @ISA     = qw(Apache::Session::Browseable::DBI Apache::Session);

*serialize = \&Apache::Session::Serialize::Storable::serialize;
*unserialize = \&Apache::Session::Serialize::Storable::unserialize;

sub populate {
    my $self = shift;

    $self->{object_store} = new Apache::Session::Browseable::Store::MySQL $self;
    $self->{lock_manager} = new Apache::Session::Lock::Null $self;
    $self->{generate}     = \&Apache::Session::Generate::MD5::generate;
    $self->{validate}     = \&Apache::Session::Generate::MD5::validate;
    $self->{serialize}    = \&serialize;
    $self->{unserialize}  = \&unserialize;

    return $self;
}

1;

__END__
=head1 NAME

Apache::Session::Browseable::MySQL - Add index and search methods to
Apache::Session::MySQL

=head1 SYNOPSIS

  use Apache::Session::Browseable::MySQL;

  my $args = {
       DataSource => 'dbi:mysql:sessions',
       UserName   => $db_user,
       Password   => $db_pass,
       LockDataSource => 'dbi:mysql:sessions',
       LockUserName   => $db_user,
       LockPassword   => $db_pass,

       # Choose your browseable fileds
       Index          => 'uid mail',
  };
  
  # Use it like Apache::Session
  my %session;
  tie %session, 'Apache::Session::Browseable::MySQL', $id, $args;
  $session{uid} = 'me';
  $session{mail} = 'me@me.com';
  $session{unindexedField} = 'zz';
  untie %session;
  
  # Apache::Session::Browseable add some global class methods
  #
  # 1) search on a field (indexed or not)
  my $hash = Apache::Session::Browseable::MySQL->searchOn( $args, 'uid', 'me' );
  foreach my $id (keys %$hash) {
    print $id . ":" . $hash->{$id}->{mail} . "\n";
  }

  # 2) Parse all sessions
  # a. get all sessions
  my $hash = Apache::Session::Browseable::MySQL->get_key_from_all_sessions();

  # b. get some fields from all sessions
  my $hash = Apache::Session::Browseable::MySQL->get_key_from_all_sessions('uid', 'mail')

  # c. execute something with datas from each session :
  #    Example : get uid and mail if mail domain is
  my $hash = Apache::Session::Browseable::MySQL->get_key_from_all_sessions(
              sub {
                 my ( $session, $id ) = @_;
                 if ( $session->{mail} =~ /mydomain.com$/ ) {
                     return { $session->{uid}, $session->{mail} };
                 }
              }
  );
  foreach my $id (keys %$hash) {
    print $id . ":" . $hash->{$id}->{uid} . "=>" . $hash->{$id}->{mail} . "\n";
  }

=head1 DESCRIPTION

Apache::Session::browseable provides some class methods to manipulate all
sessions and add the capability to index some fields to make research faster.

=head1 SEE ALSO

L<Apache::Session>

=head1 AUTHOR

Xavier Guimard, E<lt>x.guimard@free.frE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2009 by Xavier Guimard

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.1 or,
at your option, any later version of Perl 5 you may have available.

=cut
