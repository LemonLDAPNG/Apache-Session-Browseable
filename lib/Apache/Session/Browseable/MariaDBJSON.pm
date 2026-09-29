package Apache::Session::Browseable::MariaDBJSON;

use strict;

use Apache::Session::Lock::Null;
use Apache::Session::Browseable::Store::MariaDBJSON;
use Apache::Session::Generate::SHA256;
use Apache::Session::Serialize::JSON;
use Apache::Session::Browseable::MySQLJSON;

our $VERSION = '1.3.20';
our @ISA     = qw(Apache::Session::Browseable::MySQLJSON);

sub populate {
    my $self = shift;

    $self->{object_store} =
      new Apache::Session::Browseable::Store::MariaDBJSON $self;
    $self->{lock_manager} = new Apache::Session::Lock::Null $self;
    $self->{generate}     = \&Apache::Session::Generate::SHA256::generate;
    $self->{validate}     = \&Apache::Session::Generate::SHA256::validate;
    $self->{serialize}    = \&Apache::Session::Serialize::JSON::serialize;
    $self->{unserialize}  = \&Apache::Session::Serialize::JSON::unserialize;

    return $self;
}

# Indexed fields are read from the generated column of the same name: MariaDB
# doesn't always use the index of a generated column when a query contains
# its expression
sub _sqlField {
    my ( $class, $dbh, $field, $args ) = @_;
    if ( $args and $class->_fieldIsIndexed( $args, $field ) ) {
        $class->_checkIndex( $dbh, $args );
        my ($f) = $class->_utf8($field);
        $f =~ s/`/``/g;
        return "`$f`";
    }
    return 'JSON_VALUE(a_session, ' . $class->_sqlPath( $dbh, $field ) . ')';
}

# Indexed fields are read from a generated column: a column that exists but
# is not generated (for example left over from a migration from
# Browseable::MySQL, where the store wrote real columns) stays NULL, so
# searches and purge silently return nothing. Check it once per handle and
# table
sub _checkIndex {
    my ( $class, $dbh, $args ) = @_;
    my $index =
      ref( $args->{Index} ) ? $args->{Index} : [ split /\s+/, $args->{Index} ];
    return unless (@$index);

    my $table = $args->{TableName} || $Apache::Session::Store::DBI::TableName;
    my $checked = $dbh->{asb_mariadbjson_index} ||= {};
    return if ( $checked->{$table} );

    my $sth = $dbh->prepare(
        'SELECT COLUMN_NAME, GENERATION_EXPRESSION'
          . ' FROM information_schema.COLUMNS'
          . ' WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?'
          . ' AND COLUMN_NAME IN ('
          . join( ',', ('?') x @$index ) . ')' );
    $sth->execute( $table, @$index );
    my %expr = map { $_->[0] => $_->[1] } @{ $sth->fetchall_arrayref };
    $sth->finish;

    foreach my $field (@$index) {
        next
          if ( defined( $expr{$field} )
            and $expr{$field} =~ /\ba_session\b/ );
        my $why = exists( $expr{$field} )
          ? 'it exists but is not generated from a_session'
          : 'there is no column with this name';
        die "Apache::Session::Browseable::MariaDBJSON: Index field "
          . "\"$field\" is unusable in table $table: $why. Searches on it"
          . " would silently return nothing; add a generated column based on"
          . " a_session (see the documentation)\n";
    }
    $checked->{$table} = 1;
    return;
}

# No CAST for indexed fields: it would prevent the use of the index
sub _buildLowerThanExpression {
    my ( $class, $field, $value, $dbh, $args ) = @_;
    return $class->_sqlField( $dbh, $field, $args ) . " < $value"
      if ( $args and $class->_fieldIsIndexed( $args, $field ) );
    return $class->SUPER::_buildLowerThanExpression( $field, $value, $dbh );
}

1;
__END__

=head1 NAME

Apache::Session::Browseable::MariaDBJSON - Add index and search methods to
Apache::Session::MySQL for MariaDB, using a JSON field

=head1 SYNOPSIS

Create table. Example for Lemonldap::NG with generated columns and indexes:

  CREATE TABLE sessions (
      id varchar(64) not null primary key,
      a_session json,
      _whatToTrace varchar(255) COLLATE utf8mb4_bin
          AS (JSON_VALUE(a_session, '$._whatToTrace')) VIRTUAL,
      _session_kind varchar(32) COLLATE utf8mb4_bin
          AS (JSON_VALUE(a_session, '$._session_kind')) VIRTUAL,
      _utime bigint unsigned
          AS (cast(JSON_VALUE(a_session, '$._utime') as unsigned)) VIRTUAL,
      _lastSeen bigint unsigned
          AS (cast(JSON_VALUE(a_session, '$._lastSeen') as unsigned)) VIRTUAL,
      ipAddr varchar(64) COLLATE utf8mb4_bin
          AS (JSON_VALUE(a_session, '$.ipAddr')) VIRTUAL,
      KEY _whatToTrace (_whatToTrace),
      KEY _session_kind (_session_kind),
      KEY _utime (_utime),
      KEY _lastSeen (_lastSeen),
      KEY ipAddr (ipAddr)
  ) ENGINE=InnoDB;

In MariaDB, C<json> is an alias for C<longtext COLLATE utf8mb4_bin
CHECK (json_valid(a_session))>.

Use it with Perl:

  use Apache::Session::Browseable::MariaDBJSON;

  my $args = {
       DataSource => 'dbi:MariaDB:database=sessions', # or dbi:mysql:...
       UserName   => $db_user,
       Password   => $db_pass,

       # Fields that have a generated column
       Index      => '_whatToTrace _session_kind _utime _lastSeen ipAddr',
  };

Use it like L<Apache::Session::Browseable::MySQL>.

=head2 Generated columns

Any field can be searched, but only the fields listed in C<Index> can use an
index. Each of them must have a generated column (C<VIRTUAL> or
C<PERSISTENT>) with an index. Rules:

=over

=item *

The column name must be exactly the field name: this module queries
the column itself because MariaDB doesn't reliably use the index of a
generated column when a query contains its expression (10.11 never does,
11.8 never does for C<LIKE>).

=item *

Columns must be generated from C<a_session>: this module writes only
C<id> and C<a_session>.

=item *

C<VIRTUAL> columns are computed when read and use no space in the table
(their index does). C<PERSISTENT> columns are stored: they use more space but
are not recomputed.

=item *

Text columns must use the C<utf8mb4_bin> collation, as in the example above:
otherwise indexed fields follow the table collation (by default,
case-insensitive, and also accent-insensitive with MariaDB 11) whereas other
fields are compared exactly.

=item *

C<_utime>, C<_lastSeen> (and other indexed fields used by
deleteIfLowerThan()) must be integer columns: deleteIfLowerThan() compares
the column directly (it casts other fields to C<unsigned>).

=item *

With strict SQL mode, a value that doesn't fit into its column (too
long string, non-integer C<_utime> or C<_lastSeen>) makes the session storage
fail: size C<varchar> columns generously; Lemonldap::NG always writes integer
C<_utime> and C<_lastSeen>.

=back

C<_lastSeen> is needed when Lemonldap::NG "timeoutActivity" is used: sessions
purge then deletes sessions whose C<_utime> B<or> C<_lastSeen> is too old,
and an C<OR> with a non indexed side forces a full table scan (with both
columns, MariaDB uses an C<index_merge>).

Fields that are not listed in C<Index> are read with
C<JSON_VALUE(a_session, '$.field')>. C<JSON_VALUE> returns C<NULL> for missing
fields, JSON C<null>, arrays and objects: such values can't be searched and
get_key_from_all_sessions() returns C<undef> for them when called with field
names.

Searches are exact (case- and accent-sensitive) for all fields, as long as
generated text columns use the C<utf8mb4_bin> collation (see above). Field
names and searched values are character strings: a UTF-8 encoded byte string
doesn't match non-ASCII values.

To add a generated column to an existing table:

  ALTER TABLE sessions
      ADD COLUMN ipAddr varchar(64) COLLATE utf8mb4_bin
          AS (JSON_VALUE(a_session, '$.ipAddr')) VIRTUAL,
      ADD KEY ipAddr (ipAddr);

=head1 DESCRIPTION

Apache::Session::browseable provides some class methods to manipulate all
sessions and add the capability to index some fields to make research faster.

Apache::Session::Browseable::MariaDBJSON implements it for MariaDB databases,
storing sessions in JSON and using generated columns for indexed fields. It
works with DBD::MariaDB (C<dbi:MariaDB:...>) and DBD::mysql
(C<dbi:mysql:...>). It has been tested with MariaDB 10.11 and 11.8.

For MySQL, use L<Apache::Session::Browseable::MySQLJSON>.

=head1 SEE ALSO

L<Apache::Session>, L<Apache::Session::Browseable::MySQL>,
L<Apache::Session::Browseable::MySQLJSON>, L<http://lemonldap-ng.org>

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
