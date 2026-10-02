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

=head1 PERSISTENT DATABASE CONNECTIONS

SQL backends keep their database connection open between sessions: a process
opens one connection (per DataSource, user and connection attributes) the
first time a session is tied, and uses it again for the next ones. With TLS
or a remote database, opening a connection costs more than the session access
itself.

This applies to all DBI backends (Postgres, PgJSON, PgHstore, Patroni, MySQL,
MySQLJSON, SQLite, Oracle, Sybase, Informix and Cassandra). The
handle is cached by DBI C<connect_cached()>, which checks it with C<ping()>
and reconnects if the connection was lost. It is opened with the attributes
that these backends always used (C<AutoCommit> in particular) and gets the
same flags (C<pg_enable_utf8>, C<mysql_enable_utf8>, C<sqlite_unicode>).

To get the previous behaviour, one connection opened when a session is tied
and closed at untie, set the C<noreuse> argument to a true value. Example
with Lemonldap::NG, to disable the reuse in C<globalStorageOptions>:

  globalStorage        => 'Apache::Session::Browseable::Postgres',
  globalStorageOptions => {
      DataSource => 'dbi:Pg:dbname=sessions;host=db.example.com;sslmode=require',
      UserName   => 'lemonldap',
      Password   => 'secret',
      TableName  => 'sessions',
      Commit     => 1,
      Index      => '_whatToTrace _session_kind _utime _lastSeen ipAddr',
      noreuse    => 1,
  },

A C<Handle> argument has precedence over the connection cache.
L<Apache::Session::Browseable::Redis> has its own C<reuse> option, which is
unrelated.

Things to know:

=over

=item *

Each process (Apache or FastCGI worker...) keeps its connection(s) open: size
the maximum number of connections of the database server for the number of
processes, or use C<noreuse>. A handle belongs to the process that opened
it: it is not meant to be used by a child created by C<fork()>.

=item *

Backends that use transactions (C<AutoCommit> off: Postgres, PgJSON,
PgHstore, Patroni, SQLite, Oracle, Sybase and Informix) end the transaction
each time a session is untied, even after a failure: it is committed if
C<Commit> is set, rolled back otherwise. So set C<Commit =E<gt> 1> with these
backends (SQLite and Patroni set it by default). No transaction, and so no
row lock taken by a write, stays open on the connection.

=item *

Sessions tied at the same time in a process share the connection, and so the
transaction: untying one of them also commits (or rolls back) the changes
already done in the others. Use C<noreuse> if you need to keep several
sessions tied at once with independent transactions.

=item *

Search methods (searchOn(), get_key_from_all_sessions(),
deleteIfLowerThan()...) already use a persistent connection, with
C<AutoCommit> on. MySQL and MySQLJSON sessions use the same
attributes and share it; with the other backends, a process that also calls
search methods keeps two connections.

=back

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
