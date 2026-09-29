package Apache::Session::Browseable::DBI;

use strict;

use DBI;
use Apache::Session;
use Apache::Session::Browseable::_common;

our $VERSION = '1.3.9';
our @ISA     = qw(Apache::Session Apache::Session::Browseable::_common);

sub searchOn {
    my $class = shift;
    my ( $args, $selectField, $value, @fields ) = @_;

    # Escape quotes
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

sub searchLt {
    my $class = shift;
    return $class->_searchCompare( '<', @_ );
}

sub searchGt {
    my $class = shift;
    return $class->_searchCompare( '>', @_ );
}

# Sessions without the field are skipped, also when it is compared in Perl
# (fields not listed in Index). $value is checked, then inserted like
# deleteIfLowerThan() thresholds: bound, it would take the type of the cast
# (bigint in PostgreSQL) and decimal values would fail
sub _searchCompare {
    my ( $class, $op, $args, $selectField, $value, @fields ) = @_;
    $value = $class->_checkSearchValue( $op, $value );
    return {} unless ( defined $value );

    # Escape quotes as in searchOn(): _fieldIsIndexed() and the query must
    # test the same name
    my $field = $selectField;
    $field =~ s/'/''/g;
    unless ( $class->_fieldIsIndexed( $args, $field ) ) {
        return $class->_searchByTest(
            $args,
            $selectField,
            sub {
                defined( $_[0] )
                  and ( $op eq '<' ? $_[0] < $value : $_[0] > $value );
            },
            @fields
        );
    }
    my $query = $class->_buildCompareExpression( $field, $op, $value );
    return $class->_query( $args, $field, $value,
        { query => $query, values => [] }, @fields );
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
        my $sub = $class->_unserializer;
        while ( my @row = $sth->fetchrow_array ) {
            eval {
                my $tmp = &$sub( { serialized => $row[1] } );
                if (@fields) {
                    $res{ $row[0] }->{$_} = $tmp->{$_} foreach (@fields);
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
    }
    return \%res;
}

sub deleteIfLowerThan {
    my ( $class, $args, $rule ) = @_;
    my ( $query, %fields, @bind );
    my $index =
      ref( $args->{Index} )
      ? $args->{Index}
      : [ split /\s+/, $args->{Index} ];
    return wantarray ? ( 0, 0 ) : 0 unless ( $class->_checkThresholds($rule) );
    if ( $rule->{or} ) {
        $query = join ' OR ', map {
            $fields{$_}++;
            $class->_buildLowerThanExpression( $_, $rule->{or}->{$_} )
          }
          keys %{ $rule->{or} };
    }
    elsif ( $rule->{and} ) {
        $query = join ' AND ', map {
            $fields{$_}++;
            $class->_buildLowerThanExpression( $_, $rule->{and}->{$_} )
          }
          keys %{ $rule->{and} };
    }
    if ( $rule->{not} ) {
        $query = "($query) AND " . join(
            ' AND ',
            map {
                $fields{$_}++;
                push @bind, $rule->{not}->{$_};
                "$_ <> ?"
              }
              keys %{ $rule->{not} }
        );
    }
    return 0
      unless ( $query and $class->_tabInTab( [ keys %fields ], $index ) );
    my $dbh        = $class->_classDbh($args);
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

# Overriding this only changes deleteIfLowerThan(): searchLt() and searchGt()
# use _buildCompareExpression()
sub _buildLowerThanExpression {
    my ( $class, $field, $value, @args ) = @_;
    return $class->_buildCompareExpression( $field, '<', $value, @args );
}

# Let specialized modules override this syntax if they need to. $op is "<" or
# ">", $value a number checked by the caller
sub _buildCompareExpression {
    my ( $class, $field, $op, $value ) = @_;
    die "_buildCompareExpression: invalid operator '$op'\n"
      unless ( $op eq '<' or $op eq '>' );
    return "cast($field as integer) $op $value";
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
    my %res;
    my $next = (
        $args->{DataSource} =~ /^sybase/i
        ? sub {
            require Storable;
            return Storable::thaw( pack( 'H*', $_[0] ) );
          }
        : $args->{DataSource} =~ /^mysql/i ? sub {
            require MIME::Base64;
            require Storable;
            return Storable::thaw( MIME::Base64::decode_base64( $_[0] ) );
          }
        : undef
    );
    my $sub = $class->_unserializer;
    $class->_forEachSession(
        $dbh,
        $table_name,
        sub {
            my @row = @_;
            eval {
                my $tmp = &$sub( { serialized => $row[1] }, $next );
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
    if ( $datasource =~ /^dbi:sqlite/i ) {
        $dbh->{sqlite_unicode} = 1;
    }
    elsif ( $datasource =~ /^dbi:mysql/i ) {
        $dbh->{mysql_enable_utf8} = 1;
    }
    elsif ( $datasource =~ /^dbi:pg/i ) {
        $dbh->{pg_enable_utf8} = 1;
    }
    return $dbh;
}

1;

