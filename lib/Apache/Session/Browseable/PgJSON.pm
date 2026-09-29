package Apache::Session::Browseable::PgJSON;

use strict;

use Apache::Session;
use Apache::Session::Lock::Null;
use Apache::Session::Browseable::Store::Postgres;
use Apache::Session::Generate::SHA256;
use Apache::Session::Serialize::JSON;
use JSON qw(to_json);

our $VERSION = '1.3.9';
our @ISA     = qw(Apache::Session);

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

sub searchOn {
    my ( $class, $args, $selectField, $value, @fields ) = @_;
    if ( $args->{GinIndex} and !$class->_jsonbColumn($args) ) {
        $args = { %$args };
        delete $args->{GinIndex};
    }
    return $class->_query( $args,
        $class->_searchOnQuery( $args, $selectField, $value ), @fields );
}

# With GinIndex, add jsonb containment conditions that can use a GIN index
# on a_session. "->>" also returns the text of numbers and booleans, so a
# value that looks like one of them is searched in both forms. The "->>"
# comparison is kept: results are exactly the same as without GinIndex.
sub _searchOnQuery {
    my ( $class, $args, $field, $value ) = @_;
    ( my $q = $field ) =~ s/'/''/g;
    my $f = "a_session ->> '$q'";

    # "->>" returns arrays and objects as JSON text; jsonb rejects NUL
    return { query => "$f =?", values => [$value] }
      unless ( $args->{GinIndex}
        and defined($value)
        and $value !~ /^[\[{]/
        and "$field$value" !~ /\0/ );

    # Numbers beyond PostgreSQL numeric limits can't be stored in jsonb
    my $literal = $value =~ /^(?:true|false)\z/
      || (  $value =~ /^-?(0|[1-9][0-9]*)(?:\.([0-9]+))?\z/
        and length($1) <= 131072
        and length( $2 // '' ) <= 16383 );
    my @docs = ( to_json( { $field => "$value" } ) );
    push @docs, '{' . to_json( "$field", { allow_nonref => 1 } ) . ":$value}"
      if ($literal);
    return {
        query => '('
          . join( ' OR ', ('a_session @> ?::jsonb') x @docs )
          . ") AND $f =?",
        values => [ @docs, $value ],
    };
}

# The "a_session @> ..." conditions need a jsonb column: with a json column
# every searchOn() would fail. Look the type up once per handle and table,
# warn and fall back to the plain query when it is not jsonb.
sub _jsonbColumn {
    my ( $class, $args ) = @_;

    my $dbh = $class->_classDbh($args);
    my $table = $args->{TableName} || $Apache::Session::Store::DBI::TableName;
    my $cache = $dbh->{private_pgjson_type} ||= {};
    unless ( exists $cache->{$table} ) {
        ( $cache->{$table} ) = $dbh->selectrow_array(
            q{SELECT t.typname FROM pg_attribute a
                JOIN pg_type t ON t.oid = a.atttypid
               WHERE a.attrelid = to_regclass(?) AND a.attname = 'a_session'
                 AND NOT a.attisdropped},
            undef, $table
        );
        warn "GinIndex ignored: $table.a_session is not jsonb\n"
          unless ( $cache->{$table} || '' ) eq 'jsonb';
    }
    return ( $cache->{$table} || '' ) eq 'jsonb';
}

sub searchOnExpr {
    my ( $class, $args, $selectField, $value, @fields ) = @_;
    $selectField =~ s/'/''/g;
    $value       =~ s/\*/%/g;
    my $query =
      { query => "a_session ->> '$selectField' like ?", values => [$value] };
    return $class->_query( $args, $query, @fields );
}

sub _query {
    my ( $class, $args, $query, @fields ) = @_;
    my %res = ();

    my $dbh        = $class->_classDbh($args);
    my $table_name = $args->{TableName}
      || $Apache::Session::Store::DBI::TableName;

    my $sth;
    my $fields =
      @fields
      ? join( ',', 'id', map { s/'//g; "a_session ->> '$_' AS $_" } @fields )
      : '*';
    $sth =
      $dbh->prepare("SELECT $fields from $table_name where $query->{query}");
    $sth->execute( @{ $query->{values} } );

    # In this case, PostgreSQL change field name in lowercase
    my $res = $sth->fetchall_hashref('id') or return {};
    if (@fields) {
        foreach (@fields) {
            if ( $_ ne lc($_) ) {
                foreach my $s ( keys %$res ) {
                    $res->{$s}->{$_} = delete $res->{$s}->{ lc $_ };
                }
            }
        }
    }
    else {
        my $self = eval "&${class}::populate();";
        my $sub  = $self->{unserialize};
        foreach my $s ( keys %$res ) {
            eval {
                my $tmp = &$sub( { serialized => $res->{$s}->{a_session} } );
                $res->{$s} = $tmp;
            };
            if ($@) {
                print STDERR "Error in session $s: $@\n";
                delete $res->{$s};
            }
        }
    }
    return $res;
}

sub deleteIfLowerThan {
    my ( $class, $args, $rule ) = @_;
    my $query;
    if ( $rule->{or} ) {
        $query = join ' OR ',
          map { "cast(a_session ->> '$_' as bigint) < $rule->{or}->{$_}" }
          keys %{ $rule->{or} };
    }
    elsif ( $rule->{and} ) {
        $query = join ' AND ',
          map { "cast(a_session ->> '$_' as bigint) < $rule->{or}->{$_}" }
          keys %{ $rule->{or} };
    }
    if ( $rule->{not} ) {
        $query = "($query) AND "
          . join( ' AND ',
            map { "a_session ->> '$_' <> '$rule->{not}->{$_}'" }
              keys %{ $rule->{not} } );
    }
    return 0 unless ($query);
    my $dbh        = $class->_classDbh($args);
    my $table_name = $args->{TableName}
      || $Apache::Session::Store::DBI::TableName;
    my $rows = $dbh->do("DELETE FROM $table_name WHERE $query");
    return 0 unless defined $rows;

    if (wantarray) {
        $rows = 0 if $rows == -1;
        return ( 1, $rows );
    }
    else {
        return 1;
    }
}

sub get_key_from_all_sessions {
    my ( $class, $args, $data ) = @_;

    my $table_name = $args->{TableName}
      || $Apache::Session::Store::DBI::TableName;
    my $dbh = $class->_classDbh($args);
    my $sth;

    # Special case if all wanted fields are indexed
    if ( $data and ref($data) ne 'CODE' ) {
        $data = [$data] unless ( ref($data) );
        my $fields = join ',', 'id',
          map { s/'//g; "a_session ->> '$_' AS \"$_\"" } @$data;
        $sth = $dbh->prepare("SELECT $fields from $table_name");
        $sth->execute;
        return $sth->fetchall_hashref('id');
    }
    $sth = $dbh->prepare_cached("SELECT id,a_session from $table_name");
    $sth->execute;
    my %res;
    while ( my @row = $sth->fetchrow_array ) {
        no strict 'refs';
        my $self = eval "&${class}::populate();";
        eval {
            my $sub = $self->{unserialize};
            my $tmp = &$sub( { serialized => $row[1] } );
            if ( ref($data) eq 'CODE' ) {
                $tmp = &$data( $tmp, $row[0] );
                $res{ $row[0] } = $tmp if ( defined($tmp) );
            }
            elsif ($data) {
                $data = [$data] unless ( ref($data) );
                $res{ $row[0] }->{$_} = $tmp->{$_} foreach (@$data);
            }
            else {
                $res{ $row[0] } = $tmp;
            }
        };
        if ($@) {
            print STDERR "Error in session $row[0]: $@\n";
            delete $res{ $row[0] };
        }
    }
    return \%res;
}

sub _classDbh {
    my ( $class, $args ) = @_;

    my $datasource = $args->{DataSource} or die "No datasource given !";
    my $username   = $args->{UserName};
    my $password   = $args->{Password};
    my $dbh =
      DBI->connect_cached( $datasource, $username, $password,
        { RaiseError => 1, AutoCommit => 1 } )
      || die $DBI::errstr;
    $dbh->{pg_enable_utf8} = 1;
    return $dbh;
}

1;
__END__

=head1 NAME

Apache::Session::Browseable::PgJSON - Hstore type support for
L<Apache::Session::Browseable::Postgres>

=head1 SYNOPSIS

Create table:

  CREATE UNLOGGED TABLE sessions (
      id varchar(64) not null primary key,
      a_session jsonb,
  );

Optionally, add indexes on some fields. Example for Lemonldap::NG:

  CREATE INDEX uid1 ON sessions USING BTREE ( (a_session ->> '_whatToTrace') );
  CREATE INDEX  s1  ON sessions ( (a_session ->> '_session_kind') );
  CREATE INDEX  u1  ON sessions ( ( cast(a_session ->> '_utime' AS bigint) ) );
  CREATE INDEX ip1  ON sessions USING BTREE ( (a_session ->> 'ipAddr') );

A single GIN index can replace the btree indexes used only for equality
searches (like C<s1>), but it is much bigger and slows down updates: see
L</GIN INDEX>.

Use it like L<Apache::Session::Browseable::Postgres> except that you don't
need to declare indexes

=head1 DESCRIPTION

Apache::Session::Browseable provides some class methods to manipulate all
sessions and add the capability to index some fields to make research faster.

Apache::Session::Browseable::PgJSON implements it for PosqtgreSQL databases
using "json" or "jsonb" type to be able to browse sessions. The C<GinIndex>
option requires "jsonb".

=head1 GIN INDEX

Instead of one btree index per searched field, one GIN index can serve
searchOn() on B<any> field:

  CREATE INDEX gin1 ON sessions USING GIN (a_session jsonb_path_ops);

It is used only if C<GinIndex> is set in the arguments (for Lemonldap::NG, in
sessions storage options):

  GinIndex => 1,

searchOn() then adds a C<a_session @E<gt> '{"field":"value"}'> condition, the
only kind of query this index can serve. The C<@E<gt>> operator and the
C<jsonb_path_ops> operator class exist only for "jsonb": with a "json"
column, the index can't be created and searchOn() fails. Convert the column
first:

  ALTER TABLE sessions ALTER COLUMN a_session TYPE jsonb
    USING a_session::jsonb;

If the column is not "jsonb", C<GinIndex> is ignored: a warning is emitted
once per table and searchOn() falls back to the query used without the option.

Results are the same as without C<GinIndex>:

=over

=item * Containment is type sensitive while the C<-E<gt>E<gt>> operator used
without C<GinIndex> is not: searching C<123> finds both the string C<"123">
and the number C<123> (like C<_utime>). So a value that looks like a JSON
number or boolean is searched in both forms, with two index scans combined by
a C<BitmapOr>.

=item * The C<-E<gt>E<gt>> comparison is kept to filter the rows found by the
index: for example, C<{"k":1.50}> contains C<{"k":1.5}> but searching C<1.5>
must not find C<1.50>.

=item * Numbers beyond PostgreSQL numeric limits (more than 131072 digits
before the decimal point or 16383 after) can't be stored in "jsonb": such
values are searched as strings only.

=item * Values starting with C<[> or C<{> (possible text of JSON arrays and
objects) and values or field names containing a NUL character are searched
without the GIN index.

=back

Measured on PostgreSQL 17 with 300,000 realistic Lemonldap::NG sessions
(391 MB table):

=over

=item * the GIN index takes 167 MB, versus 15 MB for the C<uid1>, C<s1>,
C<u1> and C<ip1> btree indexes above;

=item * searchOn() lookups through the GIN index or through a btree index are
comparable, well under 1 ms. The gain is on fields without btree index:
0.04 ms instead of a 30 ms full table scan;

=item * updating 30,000 sessions takes 6.3 s with the GIN index, versus 1.9 s
without it (about 3 times slower). The 4 btree indexes above were present in
both runs.

=back

Sessions are updated often (C<_utime>, C<_lastSeen>), so this write cost
usually outweighs the lookup gain. The GIN index is interesting when searchOn()
is used on many fields that have no btree index. Enabling C<GinIndex> without
the index only adds useless conditions.

The GIN index doesn't help searchOnExpr() (C<LIKE>), deleteIfLowerThan()
(C<E<lt>> comparisons, and C<not> rules that must also match sessions without
the field) nor get_key_from_all_sessions(). Keep the C<uid1>, C<u1>, C<ls1>
and C<ip1> btree indexes above alongside it; C<s1> is not needed anymore.
PostgreSQL may still prefer a btree index on the searched field, or a full
scan for a frequent value like C<_session_kind = 'SSO'>.

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
