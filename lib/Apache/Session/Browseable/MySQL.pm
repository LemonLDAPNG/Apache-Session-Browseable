package Apache::Session::Browseable::MySQL;

use strict;

use Apache::Session;
use Apache::Session::Lock::Null;
use Apache::Session::Browseable::Store::MySQL;
use Apache::Session::Generate::SHA256;
use Apache::Session::Serialize::JSON;
use Apache::Session::Browseable::DBI;

our $VERSION = '1.2.5';
our @ISA     = qw(Apache::Session::Browseable::DBI Apache::Session);

sub populate {
    my $self = shift;

    $self->{object_store} = new Apache::Session::Browseable::Store::MySQL $self;
    $self->{lock_manager} = new Apache::Session::Lock::Null $self;
    $self->{generate}     = \&Apache::Session::Generate::SHA256::generate;
    $self->{validate}     = \&Apache::Session::Generate::SHA256::validate;
    $self->{serialize}    = \&Apache::Session::Serialize::JSON::serialize;
    $self->{unserialize}  = \&Apache::Session::Serialize::JSON::unserialize;

    return $self;
}

# No CAST (default in DBI.pm): MySQL converts values implicitly and a CAST
# prevents the use of an index on the field
sub _buildCompareExpression {
    my ( $class, $field, $op, $value ) = @_;
    return "$field $op $value";
}

1;
__END__

=head1 NAME

Apache::Session::Browseable::MySQL - Add index and search methods to
Apache::Session::MySQL

=head1 SYNOPSIS

Create table with columns for indexed fields. Example for Lemonldap::NG:

  CREATE TABLE sessions (
      id varchar(64) not null primary key,
      a_session text,
      _whatToTrace varchar(255) COLLATE utf8mb4_bin,
      _session_kind varchar(32) COLLATE utf8mb4_bin,
      _utime bigint,
      _lastSeen bigint,
      _oidcRtUpdate bigint,
      ipAddr varchar(64) COLLATE utf8mb4_bin
  );

Add indexes:

  CREATE INDEX uid1 ON sessions (_whatToTrace) USING BTREE;
  CREATE INDEX s1   ON sessions (_session_kind);
  CREATE INDEX u1   ON sessions (_utime);
  CREATE INDEX ls1  ON sessions (_lastSeen);
  CREATE INDEX rt1  ON sessions (_oidcRtUpdate);
  CREATE INDEX ip1  ON sessions (ipAddr) USING BTREE;

Indexed columns can't be C<text>: MySQL can't index them without a prefix
length. C<_utime> must be numeric (C<bigint>) so that deleteIfLowerThan() can
use its index.

C<_lastSeen> column and index are needed when Lemonldap::NG "timeoutActivity"
is used: sessions purge then calls deleteIfLowerThan() on C<_utime> and
C<_lastSeen>, which does nothing unless both fields are in C<Index> (purge
then falls back to reading all sessions).

To add C<_lastSeen> to an existing table, do it B<before> adding the field to
C<Index>: the module writes every C<Index> column, so a missing column makes
every session write fail. First create the column and its index:

  ALTER TABLE sessions ADD COLUMN _lastSeen bigint;
  CREATE INDEX ls1 ON sessions (_lastSeen);

then backfill it (see L<Apache::Session::Browseable/"ADDING A COLUMN TO Index ON AN EXISTING TABLE">)
and only then add C<_lastSeen> to C<Index>.

Searches must be exact (case and accent sensitive). Text columns listed in
C<Index> must use the C<utf8mb4_bin> collation: otherwise, searches on indexed
fields follow the table collation (case and accent insensitive with
C<utf8mb4_0900_ai_ci>, the default of MySQL 8) whereas searches on other fields
are done by Perl and are always exact. Without C<utf8mb4_bin>,
C<searchOn($args, '_whatToTrace', 'DWHO')> would find the session of C<dwho>.

Exception: C<utf8mb4_bin> is a C<PAD SPACE> collation, so C<=> ignores
trailing spaces: an indexed search for C<'dwho '> finds the sessions of
C<dwho>, whereas a search on a non indexed field (done by Perl) doesn't. To
avoid it, use a C<NO PAD> collation: C<utf8mb4_0900_bin> on MySQL E<gt>=
8.0.17 (C<utf8mb4_nopad_bin> on MariaDB).

To fix an existing table:

  ALTER TABLE sessions
      MODIFY _whatToTrace varchar(255) COLLATE utf8mb4_bin,
      MODIFY _session_kind varchar(32) COLLATE utf8mb4_bin,
      MODIFY ipAddr varchar(64) COLLATE utf8mb4_bin;

C<_oidcRtUpdate> column and index are useful when OpenID Connect relying
parties have a refresh token activity timeout: sessions purge then calls
searchLt() on C<_oidcRtUpdate>, which reads all sessions unless this field is
in C<Index>.

With strict SQL mode (default since MySQL 5.7), storing a value longer than
its column fails, so the whole session can't be saved: size C<varchar>
columns generously.

Use it with Perl:

  use Apache::Session::Browseable::MySQL;

  my $args = {
       DataSource => 'dbi:mysql:sessions',
       UserName   => $db_user,
       Password   => $db_pass,
       LockDataSource => 'dbi:mysql:sessions',
       LockUserName   => $db_user,
       LockPassword   => $db_pass,

       # Choose your browseable fileds
       Index          => '_whatToTrace _session_kind _utime _lastSeen'
                       . ' _oidcRtUpdate ipAddr',
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

=head2 searchLt() and searchGt()

  # Sessions whose _utime is lower than $time
  my $hash = Apache::Session::Browseable::MySQL->searchLt( $args,
      '_utime', $time, 'uid' );

searchLt() and searchGt() take the same arguments and return the same data as
searchOn(): sessions whose field is lower (or greater) than the given value,
which is excluded. The value must be a number (C<12>, C<-12> or C<12.5>):
otherwise nothing is returned and an error is printed on STDERR. Spaces
around the value are ignored.

Fields listed in C<Index> are compared in SQL as C<deleteIfLowerThan()> does
(no cast), so the index of the column is used. Other fields are compared in
Perl after reading all sessions.

Sessions without the field are never returned. This differs from the Perl
fallback of Lemonldap::NG, where a missing field is compared as 0: searchLt()
would then return nearly all sessions. Lemonldap::NG doesn't need them: its
sessions purge ignores sessions without C<_oidcRtUpdate>.

=head1 SEE ALSO

L<Apache::Session>

=head1 COPYRIGHT AND LICENSE

=encoding utf8

=over

=item 2009-2025 by Xavier Guimard

=item 2013-2025 by Clément Oudot

=item 2019-2025 by Maxime Besson

=item 2013-2025 by Worteks

=item 2023-2025 by Linagora

=back

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.1 or,
at your option, any later version of Perl 5 you may have available.

=cut
