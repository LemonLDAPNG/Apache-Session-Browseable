package Apache::Session::Browseable::MySQLJSON;

use strict;

use Apache::Session;
use Apache::Session::Lock::Null;
use Apache::Session::Browseable::Store::MySQL;
use Apache::Session::Generate::SHA256;
use Apache::Session::Serialize::JSON;
use Apache::Session::Browseable::DBI;

our $VERSION = '1.3.9';
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

sub searchOn {
    my ( $class, $args, $selectField, $value, @fields ) = @_;
    $selectField =~ s/'/''/g;
    my $query =
      { query => qq'a_session->>"\$.$selectField" =?', values => [$value] };
    return $class->_query( $args, $query, @fields );
}

sub searchOnExpr {
    my ( $class, $args, $selectField, $value, @fields ) = @_;
    $selectField =~ s/'/''/g;
    $value       =~ s/\*/%/g;
    my $query =
      { query => qq'a_session->>"\$.$selectField" like ?', values => [$value] };
    return $class->_query( $args, $query, @fields );
}

sub _query {
    my ( $class, $args, $query, @fields ) = @_;
    my %res = ();
    my $index =
      ref( $args->{Index} )
      ? $args->{Index}
      : [ split /\s+/, $args->{Index} ];

    my $dbh        = $class->_classDbh($args);
    my $table_name = $args->{TableName}
      || $Apache::Session::Store::DBI::TableName;

    my $sth;
    my $fields =
      join( ',', 'id', map { s/'//g; qq(a_session->>"\$.$_" AS $_) } @fields );
    $sth =
      $dbh->prepare("SELECT $fields from $table_name where $query->{query}");
    $sth->execute( @{ $query->{values} } );

    # In this case, PostgreSQL change field name in lowercase
    my $res = $sth->fetchall_hashref('id') or return {};
    foreach (@fields) {
        if ( $_ ne lc($_) ) {
            foreach my $s ( keys %$res ) {
                $res->{$s}->{$_} = delete $res->{$s}->{ lc $_ };
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
          map { $class->_buildLowerThanExpression( $_, $rule->{or}->{$_} ) }
          keys %{ $rule->{or} };
    }
    elsif ( $rule->{and} ) {
        $query = join ' AND ',
          map { $class->_buildLowerThanExpression( $_, $rule->{or}->{$_} ) }
          keys %{ $rule->{or} };
    }
    if ( $rule->{not} ) {
        $query = "($query) AND "
          . join( ' AND ',
            map { qq{a_session->>"\$.$_" <> '$rule->{not}->{$_}'} }
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
        my $fields = join ',',
          map { s/'//g; qq{a_session->>"\$.$_" AS $_} } @$data;
        $sth = $dbh->prepare("SELECT $fields from $table_name");
        $sth->execute;
        return $sth->fetchall_hashref('id');
    }
    my %res;
    my $sub = $class->_unserializer;
    $class->_forEachSession(
        $dbh,
        $table_name,
        sub {
            my @row = @_;
            eval {
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
    );
    return \%res;
}

# Same arguments as in DBI.pm. Must match the documented generated columns
sub _buildLowerThanExpression {
    my ( $class, $field, $value ) = @_;
    return qq{cast(a_session->>"\$.$field" as UNSIGNED) < $value};
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
    $dbh->{mysql_enable_utf8} = 1;
    return $dbh;
}

1;
__END__

=head1 NAME

Apache::Session::Browseable::MySQL - Add index and search methods to
Apache::Session::MySQL

=head1 SYNOPSIS

Create table. Example for Lemonldap::NG with optional generated columns and
indexes:

  CREATE TABLE sessions (
      id varchar(64) not null primary key,
      a_session json,
      as_wt varchar(255) AS (a_session->>'$._whatToTrace') VIRTUAL,
      as_sk varchar(32) AS (a_session->>'$._session_kind') VIRTUAL,
      as_ut bigint unsigned
          AS (cast(a_session->>'$._utime' as unsigned)) VIRTUAL,
      as_ip varchar(64) AS (a_session->>'$.ipAddr') VIRTUAL,
      KEY as_wt (as_wt),
      KEY as_sk (as_sk),
      KEY as_ut (as_ut),
      KEY as_ip (as_ip)
  ) ENGINE=InnoDB;

MySQL uses the index of a generated column only when the query contains the
same expression, so keep these expressions exactly as written: they are the
ones used by this module (C<-E<gt>E<gt>> returns unquoted values whereas
C<-E<gt>> keeps JSON quotes). MySQL doesn't use them for C<LIKE> queries, so
searchOnExpr() always scans the table. With strict SQL mode, a value longer
than its generated column makes the session storage fail: size them
accordingly.

Generated columns documented by previous versions (using C<-E<gt>>) were
never used. To fix an existing table, re-create them:

  ALTER TABLE sessions DROP COLUMN as_wt, DROP COLUMN as_sk,
      DROP COLUMN as_ut, DROP COLUMN as_ip;
  ALTER TABLE sessions
      ADD COLUMN as_wt varchar(255) AS (a_session->>'$._whatToTrace') VIRTUAL,
      ADD COLUMN as_sk varchar(32) AS (a_session->>'$._session_kind') VIRTUAL,
      ADD COLUMN as_ut bigint unsigned
          AS (cast(a_session->>'$._utime' as unsigned)) VIRTUAL,
      ADD COLUMN as_ip varchar(64) AS (a_session->>'$.ipAddr') VIRTUAL,
      ADD KEY as_wt (as_wt), ADD KEY as_sk (as_sk),
      ADD KEY as_ut (as_ut), ADD KEY as_ip (as_ip);

Use it with Perl:

  use Apache::Session::Browseable::MySQLJSON;

  my $args = {
       DataSource => 'dbi:mysql:sessions',
       UserName   => $db_user,
       Password   => $db_pass,
  };

Don't set C<Index>: any field can be searched and the store would try to
write indexed fields into columns of the same name.

Use it like L<Apache::Session::Browseable::MySQL>

=head1 DESCRIPTION

Apache::Session::browseable provides some class methods to manipulate all
sessions and add the capability to index some fields to make research faster.

Apache::Session::Browseable::MySQLJSON implements it for MySQL databases
using "json" type to be able to browse sessions.

THIS MODULE ISN'T USABLE WITH MARIADB FOR NOW.

=head1 SEE ALSO

L<Apache::Session>, L<Apache::Session::Browseable::MySQL>,
L<http://lemonldap-ng.org>

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
