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
    my $dbh   = $class->_classDbh($args);
    my $query = {
        query  => $class->_sqlField( $dbh, $selectField ) . ' =?',
        values => [$value]
    };
    return $class->_query( $args, $query, @fields );
}

sub searchOnExpr {
    my ( $class, $args, $selectField, $value, @fields ) = @_;
    my $dbh = $class->_classDbh($args);
    $value =~ s/\*/%/g;
    my $query = {
        query  => $class->_sqlField( $dbh, $selectField ) . ' like ?',
        values => [$value]
    };
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
    my ( $fields, $aliases ) = ( 'id,a_session', {} );
    ( $fields, $aliases ) = $class->_sqlSelect( $dbh, @fields ) if (@fields);
    $sth =
      $dbh->prepare("SELECT $fields from $table_name where $query->{query}");
    $sth->execute( @{ $query->{values} } );

    my $res = $sth->fetchall_hashref('id') or return {};
    $class->_renameAliases( $res, $aliases );
    unless (@fields) {
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
    my ( $query, @bind );
    return 0 unless ( $class->_checkThresholds($rule) );
    my $dbh = $class->_classDbh($args);
    if ( $rule->{or} ) {
        $query = join ' OR ', map {
            my $f = $class->_sqlField( $dbh, $_ );
            "cast($f as UNSIGNED) < $rule->{or}->{$_}"
          }
          keys %{ $rule->{or} };
    }
    elsif ( $rule->{and} ) {
        $query = join ' AND ', map {
            my $f = $class->_sqlField( $dbh, $_ );
            "cast($f as UNSIGNED) < $rule->{and}->{$_}"
          }
          keys %{ $rule->{and} };
    }
    return 0 unless ($query);
    if ( $rule->{not} and keys %{ $rule->{not} } ) {
        $query = "($query) AND " . join(
            ' AND ',
            map {
                my $f = $class->_sqlField( $dbh, $_ );
                push @bind, $rule->{not}->{$_};
                "($f IS NULL OR $f <> ?)"
              }
              keys %{ $rule->{not} }
        );
    }
    my $table_name = $args->{TableName}
      || $Apache::Session::Store::DBI::TableName;
    my $rows = $dbh->do( "DELETE FROM $table_name WHERE $query", undef, @bind );
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
        my ( $fields, $aliases ) = $class->_sqlSelect( $dbh, @$data );
        $sth = $dbh->prepare("SELECT $fields from $table_name");
        $sth->execute;
        my $res = $sth->fetchall_hashref('id');
        $class->_renameAliases( $res, $aliases );
        return $res;
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

# Build SQL expression to get a field from a_session. Field name is used as
# JSON path member, quoted if needed
sub _sqlField {
    my ( $class, $dbh, $field ) = @_;
    my $path;
    if ( $field =~ /^[A-Za-z_][A-Za-z0-9_]*\z/ ) {
        $path = "\$.$field";
    }
    else {
        ( my $f = $field ) =~ s/(["\\])/\\$1/g;
        $path = qq{\$."$f"};
    }
    return 'a_session->>' . $dbh->quote($path);
}

# Build the SELECT list for the given fields. Column aliases are generated
# (a field name may contain "?", which DBD::mysql takes for a placeholder even
# inside backquotes): returns the list and an alias => field name hash
sub _sqlSelect {
    my ( $class, $dbh, @fields ) = @_;
    my ( @select, %aliases );
    foreach my $field (@fields) {
        my $alias = 'f' . scalar(@select);
        $aliases{$alias} = $field;
        push @select, $class->_sqlField( $dbh, $field ) . " AS `$alias`";
    }
    return ( join( ',', 'id', @select ), \%aliases );
}

# Replace generated aliases by field names in results
sub _renameAliases {
    my ( $class, $res, $aliases ) = @_;
    return unless (%$aliases);
    foreach my $row ( values %$res ) {
        %$row = (
            ( map { $aliases->{$_} => $row->{$_} } keys %$aliases ),
            id => $row->{id}
        );
    }
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

Create table with columns for indexed fields. Example for Lemonldap::NG with
optional virtual tables and indexes:

  CREATE TABLE sessions (
      id varchar(64) not null primary key,
      a_session json,
      as_wt varchar(32) AS (a_session->"$._whatToTrace") VIRTUAL,
      as_sk varchar(12) AS (a_session->"$._session_kind") VIRTUAL,
      as_ut bigint AS (a_session->"$._utime") VIRTUAL,
      as_ip varchar(40) AS (a_session->"$.ipAddr") VIRTUAL,
      KEY as_wt (as_wt),
      KEY as_sk (as_sk),
      KEY as_ut (as_ut),
      KEY as_ip (as_ip)
  ) ENGINE=InnoDB;

Use it with Perl:

  use Apache::Session::Browseable::MySQLJSON;

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
