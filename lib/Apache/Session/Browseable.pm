package Apache::Session::Browseable;

our $VERSION = '1.4.0';

print STDERR "Use a sub module of Apache::Session::Browseable such as Apache::Session::Browseable::File";

1;
__END__

=head1 NAME

Apache::Session::Browseable - Add index and search methods to Apache::Session

=head1 DESCRIPTION

Apache::Session::browseable provides some class methods to manipulate all
sessions and add the capability to index some fields to make research faster.

It has been written to increase performances of LemonLDAP::NG. Read the
chosen module documentation carefully to set the indexes.

=head1 AVAILABLE MODULES

=head2 SQL databases

=head3 PostgreSQL

=over

=item L<Apache::Session::Browseable::Postgres>

=item L<Apache::Session::Browseable::PgHstore>: uses "hstore" field

=item L<Apache::Session::Browseable::PgJSON>: uses "json/jsonb" field

=item L<Apache::Session::Browseable::Patroni>: uses "json/jsonb" field and
manage connection using Patroni API to find master node of PostgreSQL cluster

=back

=head3 MySQL or MariaDB

=over

=item L<Apache::Session::Browseable::MySQL>: for MySQL and MariaDB

=item L<Apache::Session::Browseable::MySQLJSON>: for MySQL only, uses "json" field

=back

=head3 Other

=over

=item L<Apache::Session::Browseable::Informix>

=item L<Apache::Session::Browseable::Oracle>

=item L<Apache::Session::Browseable::SQLite>

=back

=head2 NoSQL

=over

=item L<Apache::Session::Browseable::Redis>

=item L<Apache::Session::Browseable::Cassandra>

=back

=head1 ADDING A COLUMN TO Index ON AN EXISTING TABLE

With the backends that store indexed fields in dedicated columns (Postgres,
MySQL, SQLite, Oracle, Informix...), the index columns are filled only when a
session is inserted or updated. If you add a column to C<Index> on a table that
already contains sessions, this column stays C<NULL> for every existing session
until it is written again. Such sessions are considered as "field absent":
C<searchOn()> and C<searchOnExpr()> do not find them, and the C<not> clause of
C<deleteIfLowerThan()> (which matches C<NULL> columns) can delete them. For
example, a purge rule like C<< not =E<gt> { _session_kind =E<gt> 'Persistent' } >>
would delete persistent sessions whose C<_session_kind> column was never filled.
Conversely, a column that was never filled never matches the C<or>/C<and>
thresholds of C<deleteIfLowerThan()> (a C<NULL> column is never lower than a
value): these sessions are not purged through that field. For example, a rule
on C<_lastSeen> alone would never purge them, while Lemonldap::NG's rule also
has C<_utime>, which still purges them.

So, before relying on a new column, you must backfill it. Which method to use
depends on the backend.

=head2 Backends that need no backfill

L<Apache::Session::Browseable::PgJSON>, L<Apache::Session::Browseable::PgHstore>,
L<Apache::Session::Browseable::MySQLJSON> and MariaDB's JSON variant use an
expression index or a generated column computed from the serialized data:
creating the index (or the generated column) computes it for every existing
row.

=head2 Backfilling in SQL (JSON serializer only)

This is possible only if the serializer is C<Apache::Session::Serialize::JSON>
(the case of Postgres, Patroni, MySQL, SQLite, Oracle...) B<and> the database
can extract a field from a JSON text. The following examples assume a table
named C<sessions> whose C<a_session> column contains the serialized session.

If a single row is not valid JSON, the whole C<UPDATE> fails and nothing is
backfilled. Such rows exist: sessions written by old versions with Storable
(the JSON serializer still reads them through C<Storable::thaw>), or corrupted
rows. The examples therefore skip them.

=over

=item PostgreSQL 16 and later

  UPDATE sessions SET _session_kind = a_session::json->>'_session_kind'
    WHERE _session_kind IS NULL AND a_session IS JSON;

Older PostgreSQL versions have no simple equivalent of C<IS JSON>: use the
generic method below.

=item MySQL / MariaDB

  UPDATE sessions
    SET _session_kind = JSON_UNQUOTE(JSON_EXTRACT(a_session, '$._session_kind'))
    WHERE _session_kind IS NULL AND JSON_VALID(a_session);

=item SQLite

Use C<json_extract(a_session, '$._session_kind')>, restricted to rows where
C<json_valid(a_session)> is true.

=item Oracle (12.1.0.2 and later)

Use C<JSON_VALUE(a_session, '$._session_kind')>.

=back

Rows skipped by these statements (and rows that were still C<NULL> after them)
must be handled with the generic method.

=head2 Backends where SQL cannot be used

=over

=item Sybase

L<Apache::Session::Browseable::Sybase> uses
C<Apache::Session::Serialize::Sybase>, not JSON: no SQL statement can extract a
field from C<a_session>.

=item Informix

The session is stored as JSON text, but Informix has no simple function to
extract a field from a text column.

=item Redis and LDAP

The index is maintained by the module only when a session is written, and there
is no SQL column to fill.

=back

Use the generic method for these backends.

=head2 Generic method: re-save every session from Perl

This works with every backend (including the ones above and non-JSON rows): read
each session and write it again, so that the store rewrites its index columns.
Set C<$class> and C<$args> as you do in your application:

  my $class = 'Apache::Session::Browseable::Postgres';   # your backend
  my $ids   = $class->get_key_from_all_sessions( $args, sub { 1 } );
  foreach my $id ( keys %$ids ) {
      tie my %s, $class, $id, $args;
      $s{_session_kind} = $s{_session_kind};   # marks the session as modified
      untie %s;
  }

Notes:

=over

=item *

Run it when the activity is low: a session updated by another process between
C<tie> and C<untie> loses that update.

=item *

It does not change C<_utime> (unless your application does it itself, as
Lemonldap::NG does), so sessions do not get a longer life.

=item *

Sessions that cannot be unserialized are reported on C<STDERR> and skipped.

=back

=head2 Do not just wait for sessions to be rewritten

Most sessions expire after the session timeout and are purged through
C<_utime>, but persistent sessions (C<_session_kind> set to C<Persistent>) never
expire and are rewritten only when the user logs in. They are exactly the ones
the C<not> clause could delete: backfill them before enabling such a rule.

=head1 SEE ALSO

L<Apache::Session>, L<http://lemonldap-ng.org>,
L<https://lemonldap-ng.org/documentation/2.0/performances#performance_test>

=head1 COPYRIGHT AND LICENSE

=encoding utf8

Copyright (C):

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
