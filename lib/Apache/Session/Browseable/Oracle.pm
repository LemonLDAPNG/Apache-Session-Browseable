package Apache::Session::Browseable::Oracle;

use strict;

use Apache::Session;
use Apache::Session::Lock::Null;
use Apache::Session::Browseable::Store::Oracle;
use Apache::Session::Generate::SHA256;
use Apache::Session::Serialize::JSON;
use Apache::Session::Browseable::DBI;

our $VERSION = '1.2.2';
our @ISA     = qw(Apache::Session::Browseable::DBI Apache::Session);

sub populate {
    my $self = shift;

    $self->{object_store} =
      new Apache::Session::Browseable::Store::Oracle $self;
    $self->{lock_manager} = new Apache::Session::Lock::Null $self;
    $self->{generate}     = \&Apache::Session::Generate::SHA256::generate;
    $self->{validate}     = \&Apache::Session::Generate::SHA256::validate;
    $self->{serialize}    = \&Apache::Session::Serialize::JSON::serialize;
    $self->{unserialize}  = \&Apache::Session::Serialize::JSON::unserialize;

    return $self;
}

# Index columns are double-quoted, see Apache::Session::Browseable::Store::Oracle
sub _quoteColumn {
    my ( $class, $dbh, $field ) = @_;
    return Apache::Session::Browseable::Store::Oracle->_quoteColumn($field);
}

# Oracle returns unquoted column names (id) in upper case and quoted ones
# (index columns) in their own case: read them in lower case, then restore
# the case of the requested fields. a_session (CLOB or LONG) is read up to
# LongReadLen bytes, as Apache::Session::Store::Oracle does
sub _classDbh {
    my ( $class, $args ) = @_;
    my $dbh = $class->SUPER::_classDbh($args);
    $dbh->{FetchHashKeyName} = 'NAME_lc';
    $dbh->{LongReadLen}      = $args->{LongReadLen} || 8 * 2**10;
    return $dbh;
}

sub searchOn {
    my $class = shift;
    my ( $args, $selectField, $value, @fields ) = @_;
    my $res = $class->SUPER::searchOn(@_);
    return $class->_restoreCase( $res, @fields );
}

sub searchOnExpr {
    my $class = shift;
    my ( $args, $selectField, $value, @fields ) = @_;
    my $res = $class->SUPER::searchOnExpr(@_);
    return $class->_restoreCase( $res, @fields );
}

sub get_key_from_all_sessions {
    my ( $class, $args, $data ) = @_;
    my $res = $class->SUPER::get_key_from_all_sessions( @_[ 1 .. $#_ ] );
    if ( defined $data and ref($data) ne 'CODE' ) {
        $class->_restoreCase( $res, ref($data) eq 'ARRAY' ? @$data : $data );
    }
    return $res;
}

1;

=head1 NAME

Apache::Session::Browseable::Oracle - Add index and search methods to
Apache::Session for Oracle databases

=head1 SYNOPSIS

Create table with columns for indexed fields. Their names B<must be quoted>
(see L</"INDEX COLUMNS">). Example for Lemonldap::NG:

  CREATE TABLE sessions (
      id varchar2(64) not null primary key,
      a_session clob,
      "_whatToTrace" varchar2(255),
      "_session_kind" varchar2(32),
      "_utime" number(20),
      "_lastSeen" number(20),
      "_oidcRtUpdate" number(20),
      "ipAddr" varchar2(64)
  );

Add indexes. deleteIfLowerThan() compares numeric fields as
C<cast("field" as integer)>, so their indexes are built on this expression:

  CREATE INDEX uid1 ON sessions ("_whatToTrace");
  CREATE INDEX s1   ON sessions ("_session_kind");
  CREATE INDEX u1   ON sessions (cast("_utime" as integer));
  CREATE INDEX ls1  ON sessions (cast("_lastSeen" as integer));
  CREATE INDEX rt1  ON sessions (cast("_oidcRtUpdate" as integer));
  CREATE INDEX ip1  ON sessions ("ipAddr");

Use it with Perl:

  use Apache::Session::Browseable::Oracle;

  my $args = {
       DataSource => 'dbi:Oracle:sessions',
       UserName   => $db_user,
       Password   => $db_pass,

       # Required: changes are committed only if Commit is set
       Commit     => 1,

       # Maximum size of a serialized session, 8 KB by default
       LongReadLen => 65536,

       # Choose your browseable fields
       Index      => '_whatToTrace _session_kind _utime _lastSeen'
                   . ' _oidcRtUpdate ipAddr',
  };

  # Use it like Apache::Session
  my %session;
  tie %session, 'Apache::Session::Browseable::Oracle', $id, $args;
  $session{uid} = 'me';
  untie %session;

  # Search, parse... like with Apache::Session::Browseable::Postgres
  my $hash = Apache::Session::Browseable::Oracle->searchOn( $args,
      '_whatToTrace', 'me', 'ipAddr' );

=head1 DESCRIPTION

Apache::Session::Browseable::Oracle implements the class methods of
L<Apache::Session::Browseable> for Oracle databases: create a table with a
column for each field listed in C<Index> and use it like
L<Apache::Session::Browseable::Postgres>.

=head2 INDEX COLUMNS

Oracle rejects unquoted column names starting with an underscore, such as
C<_whatToTrace> or C<_utime>, and reserved words such as C<uid>. So this
module double-quotes the column of each field listed in C<Index> in all its
queries. Quoted names are case sensitive: these columns must be created with
quoted names, in the exact case of the fields (C<"_whatToTrace">, not
C<_whatToTrace> nor C<"_WHATTOTRACE">). Field names can't contain double
quotes.

C<id> and C<a_session> are not quoted: create them without quotes (Oracle
stores them as C<ID> and C<A_SESSION>), as for L<Apache::Session::Oracle>.

A column created without quotes is stored in upper case (C<IPADDR> for
C<ipAddr>) and is not found. Rename it with its quoted name B<before> using
this version, else every session write fails:

  ALTER TABLE sessions RENAME COLUMN ipAddr TO "ipAddr";

Oracle doesn't accept unquoted names starting with an underscore, so the
C<_whatToTrace>, C<_utime>... columns can only have been created with quoted
names. List the columns to check their names:

  SELECT column_name FROM user_tab_columns WHERE table_name = 'SESSIONS';

=head2 LongReadLen

C<a_session> is read up to C<LongReadLen> bytes, 8 KB by default as with
L<Apache::Session::Store::Oracle>. Reading a longer session fails: set the
C<LongReadLen> argument to the maximum size of your sessions.

B<Note>: if you add a column to C<Index> on a table that already contains
sessions, backfill it before relying on it (see "ADDING A COLUMN TO Index ON AN
EXISTING TABLE" in L<Apache::Session::Browseable>).

=head1 SEE ALSO

L<Apache::Session::Browseable>, L<Apache::Session::Browseable::Postgres>,
L<Apache::Session::Oracle>

=cut
