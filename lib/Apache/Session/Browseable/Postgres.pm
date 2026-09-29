package Apache::Session::Browseable::Postgres;

use strict;

use Apache::Session;
use Apache::Session::Lock::Null;
use Apache::Session::Browseable::Store::Postgres;
use Apache::Session::Generate::SHA256;
use Apache::Session::Serialize::JSON;
use Apache::Session::Browseable::DBI;

our $VERSION = '1.3.1';
our @ISA     = qw(Apache::Session::Browseable::DBI Apache::Session);

sub populate {
    my $self = shift;

    $self->{object_store} =
      new Apache::Session::Browseable::Store::Postgres $self;
    $self->{lock_manager} = new Apache::Session::Lock::Null $self;
    $self->{generate}     = \&Apache::Session::Generate::SHA256::generate;
    $self->{validate}     = \&Apache::Session::Generate::SHA256::validate;
    $self->{serialize}    = \&Apache::Session::Serialize::JSON::serialize;
    $self->{unserialize}  = \&Apache::Session::Serialize::JSON::unserialize;

    return $self;
}

# PostgreSQL folds unquoted column names to lower case: restore the case of
# requested fields in the result set
sub _restoreCase {
    my ( $res, @fields ) = @_;
    foreach my $f (@fields) {
        next if ref($f) or $f eq lc($f);
        my $lc = lc $f;
        foreach my $s ( keys %$res ) {
            my $h = $res->{$s};
            next unless ref($h) eq 'HASH';
            $h->{$f} = delete $h->{$lc}
              if exists $h->{$lc} and not exists $h->{$f};
        }
    }
    return $res;
}

sub searchOn {
    my $class = shift;
    my ( $args, $selectField, $value, @fields ) = @_;
    my $res = $class->SUPER::searchOn(@_);
    return _restoreCase( $res, @fields );
}

sub searchOnExpr {
    my $class = shift;
    my ( $args, $selectField, $value, @fields ) = @_;
    my $res = $class->SUPER::searchOnExpr(@_);
    return _restoreCase( $res, @fields );
}

sub get_key_from_all_sessions {
    my ( $class, $args, $data ) = @_;
    my $res = $class->SUPER::get_key_from_all_sessions( @_[ 1 .. $#_ ] );
    if ( defined $data and ref($data) ne 'CODE' ) {
        _restoreCase( $res, ref($data) eq 'ARRAY' ? @$data : $data );
    }
    return $res;
}

# Cast to bigint instead of integer: PostgreSQL drops this cast on a bigint
# column, so its index can be used
sub _buildLowerThanExpression {
    my ( $class, $field, $value ) = @_;
    return "cast($field as bigint) < $value";
}

1;
__END__

=head1 NAME

Apache::Session::Browseable::Postgres - Add index and search methods to
L<Apache::Session::Postgres>

=head1 SYNOPSIS

Create table with columns for indexed fields. Example for Lemonldap::NG:

  CREATE UNLOGGED TABLE sessions (
      id varchar(64) not null primary key,
      a_session text,
      _whatToTrace text,
      _session_kind text,
      _utime bigint,
      _lastSeen bigint,
      ipAddr varchar(64)
  );

Add indexes:

  CREATE INDEX uid1 ON sessions USING BTREE (_whatToTrace text_pattern_ops);
  CREATE INDEX s1   ON sessions (_session_kind);
  CREATE INDEX u1   ON sessions (_utime);
  CREATE INDEX ls1  ON sessions (_lastSeen);
  CREATE INDEX ip1  ON sessions USING BTREE (ipAddr varchar_pattern_ops);

searchOnExpr() uses C<LIKE 'prefix%'> queries: unless the database uses the
"C" collation, PostgreSQL can't use a plain btree index for them. The
C<text_pattern_ops> and C<varchar_pattern_ops> operator classes let the same
index serve both C<=> and prefix C<LIKE> searches. Note that a search starting
with a C<*> wildcard can never use a btree index.

C<_utime> must be a C<bigint> column, else deleteIfLowerThan() can't use its
index.

C<_lastSeen> column and index are needed when Lemonldap::NG "timeoutActivity"
is used: sessions purge then calls deleteIfLowerThan() on C<_utime> and
C<_lastSeen>, which does nothing unless both fields are in C<Index> (purge
then falls back to reading all sessions).

Use it with Perl:

  use Apache::Session::Browseable::Postgres;

  my $args = {
       DataSource => 'dbi:Pg:sessions',
       UserName   => $db_user,
       Password   => $db_pass,
       Commit     => 1,

       # Choose your browseable fileds
       Index      => '_whatToTrace _session_kind _utime _lastSeen ipAddr',
  };
  
  # Use it like Apache::Session
  my %session;
  tie %session, 'Apache::Session::Browseable::Postgres', $id, $args;
  $session{uid} = 'me';
  $session{mail} = 'me@me.com';
  $session{unindexedField} = 'zz';
  untie %session;
  
  # Apache::Session::Browseable add some global class methods
  #
  # 1) search on a field (indexed or not)
  my $hash = Apache::Session::Browseable::Postgres->searchOn( $args, 'uid', 'me' );
  foreach my $id (keys %$hash) {
    print $id . ":" . $hash->{$id}->{mail} . "\n";
  }

  # 2) Parse all sessions
  # a. get all sessions
  my $hash = Apache::Session::Browseable::Postgres->get_key_from_all_sessions();

  # b. get some fields from all sessions
  my $hash = Apache::Session::Browseable::Postgres->get_key_from_all_sessions('uid', 'mail')

  # c. execute something with datas from each session :
  #    Example : get uid and mail if mail domain is
  my $hash = Apache::Session::Browseable::Postgres->get_key_from_all_sessions(
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

Apache::Session::Browseable provides some class methods to manipulate all
sessions and add the capability to index some fields to make research faster.

Apache::Session::Browseable::Postgres implements it for PosqtgreSQL databases.

=head1 SEE ALSO

L<http://lemonldap-ng.org>, L<Apache::Session::Postgres>

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
