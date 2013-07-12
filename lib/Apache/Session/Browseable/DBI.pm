package Apache::Session::Browseable::DBI;

use strict;

use DBI;
use Apache::Session;
use Apache::Session::Browseable::_common;

our $VERSION = '1.0';
our @ISA     = qw(Apache::Session Apache::Session::Browseable::_common);

sub searchOn {
    my $class = shift;
    my ( $args, $selectField, $value, @fields ) = @_;

    # Escape quotes
    $value       =~ s/'/''/g;
    $selectField =~ s/'/''/g;
    if ( $class->_fieldIsIndexed( $args, $selectField ) ) {
        return $class->_query( $args, $selectField, $value,
            { query => "$selectField=?", values => [$value] }, @fields );
    }
    else {
        return $class->SUPER::searchOn(@_);
    }
}

sub searchOnExpr {
    my $class = shift;
    my ( $args, $selectField, $value, @fields ) = @_;

    # Escape quotes
    $value       =~ s/'/''/g;
    $selectField =~ s/'/''/g;
    if ( $class->_fieldIsIndexed( $args, $selectField ) ) {
        $value =~ s/\*/%/g;
        return $class->_query( $args, $selectField, $value,
            { query => "$selectField like ?", values => [$value] }, @fields );
    }
    else {
        return $class->SUPER::searchOnExpr(@_);
    }
}

sub _query {
    my ( $class, $args, $selectField, $value, $query, @fields ) = @_;
    my %res = ();
    my $index =
      ref( $args->{Index} )
      ? $args->{Index}
      : [ split /\s+/, $args->{Index} ];

    my $dbh        = $class->_classDbh($args);
    my $table_name = $args->{TableName}
      || $Apache::Session::Store::DBI::TableName;

    # Case 1: all requested fields are also indexed
    my $indexed = $class->_tabInTab( \@fields, $index );
    my $sth;
    if ($indexed) {
        my $fields = join( ',', 'id', map { s/'//g; $_ } @fields );
        $sth = $dbh->prepare(
            "SELECT $fields from $table_name where $query->{query}");
        $sth->execute( @{ $query->{values} } );
        return $sth->fetchall_hashref('id');
    }

    # Case 1: at least one field isn't indexed, decoding is needed
    else {
        $sth =
          $dbh->prepare(
            "SELECT id,a_session from $table_name where $query->{query}");
        $sth->execute( @{ $query->{values} } );
        while ( my @row = $sth->fetchrow_array ) {
            no strict 'refs';
            my $sub = "${class}::unserialize";
            my $tmp = &$sub( { serialized => $row[1] } );
            if (@fields) {
                $res{ $row[0] }->{$_} = $tmp->{$_} foreach (@fields);
            }
            else {
                $res{ $row[0] } = $tmp;
            }
        }
    }
    return \%res;
}

sub get_key_from_all_sessions {
    my $class = shift;
    my $args  = shift;
    my $data  = shift;

    my $table_name = $args->{TableName}
      || $Apache::Session::Store::DBI::TableName;
    my $dbh = $class->_classDbh($args);

    # Special case if all wanted fields are indexed
    if ( $data and ref($data) ne 'CODE' ) {
        $data = [$data] unless ( ref($data) );
        my $index =
          ref( $args->{Index} )
          ? $args->{Index}
          : [ split /\s+/, $args->{Index} ];

        # Test if one field isn't indexed
        my $indexed = $class->_tabInTab( $data, $index );

        # OK, all fields are indexed
        if ($indexed) {
            my $sth =
              $dbh->prepare_cached( 'SELECT id,'
                  . join( ',', map { s/'/''/g; $_ } @$data )
                  . " from $table_name" );
            $sth->execute;
            return $sth->fetchall_hashref('id');
        }
    }
    my $sth = $dbh->prepare_cached("SELECT id,a_session from $table_name");
    $sth->execute;
    my %res;
    while ( my @row = $sth->fetchrow_array ) {
        no strict 'refs';
        my $sub = "${class}::unserialize";
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
    }
    return \%res;
}

sub _classDbh {
    my $class = shift;
    my $args  = shift;

    my $datasource = $args->{DataSource} or die "No datasource given !";
    my $username   = $args->{UserName};
    my $password   = $args->{Password};
    my $dbh =
      DBI->connect_cached( $datasource, $username, $password,
        { RaiseError => 1, AutoCommit => 1 } )
      || die $DBI::errstr;
}

1;

