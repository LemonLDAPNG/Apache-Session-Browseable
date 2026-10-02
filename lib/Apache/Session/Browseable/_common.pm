package Apache::Session::Browseable::_common;

use strict;
use AutoLoader 'AUTOLOAD';

our $VERSION = '1.2.2';

sub _tabInTab {
    my ( $class, $t1, $t2 ) = @_;

    # if no fields are required, return 0
    return 0 unless(@$t1 and @$t2);
    foreach my $f (@$t1) {
        unless ( grep { $_ eq $f } @$t2 ) {
            return 0;
        }
    }
    return 1;
}

sub _fieldIsIndexed {
    my ( $class, $args, $field ) = @_;
    my $index =
      ref( $args->{Index} ) ? $args->{Index} : [ split /\s+/, $args->{Index} ];
    return ( grep { $_ eq $field } @$index );
}

# Identifier (table or column name) inserted into an SQL query. It is quoted
# with the driver's quote_identifier() when the driver supports it the
# standard way. PostgreSQL folds unquoted names to lower case, so tables and
# columns created without quotes have lower case names: the name is
# lowercased before being quoted, which keeps the previous behaviour for
# names in mixed case (TableName => 'Sessions' still finds "sessions"). A
# "schema.table" name is quoted part by part, and a name that already
# contains quotes is left unchanged. Other drivers (Oracle, Sybase,
# Informix...) get the name as before: quoting would change its case or
# meaning there
sub _quoteIdentifier {
    my ( $class, $dbh, $name ) = @_;
    my $driver = $dbh->{Driver}->{Name};
    unless ( $driver =~ /^(?:Pg|mysql|MariaDB|SQLite)\z/ ) {
        $name =~ s/'/''/g;
        return $name;
    }
    return $name      if ( $name =~ /["`]/ );
    $name = lc($name) if ( $driver eq 'Pg' );
    return join '.', map { $dbh->quote_identifier($_) } split /\./, $name, -1;
}

# Column of an indexed field in SQL queries. Callers check Index with the
# field name, then insert the result of this method: backends that need
# another quoting override it
sub _quoteColumn {
    my ( $class, $dbh, $field ) = @_;
    return $class->_quoteIdentifier( $dbh, $field );
}

# Quoted table name, see _quoteIdentifier()
sub _tableName {
    my ( $class, $dbh, $args ) = @_;
    return $class->_quoteIdentifier( $dbh,
        $args->{TableName} || $Apache::Session::Store::DBI::TableName );
}

1;
__END__

sub searchOn {
    my ( $class, $args, $selectField, $value, @fields ) = splice @_;
    my %res = ();
    $class->get_key_from_all_sessions(
        $args,
        sub {
            my $entry = shift;
            my $id    = shift;
            return undef unless ( $entry->{$selectField} eq $value );
            if (@fields) {
                $res{$id}->{$_} = $entry->{$_} foreach (@fields);
            }
            else {
                $res{$id} = $entry;
            }
            undef;
        }
    );
    return \%res;
}

sub searchOnExpr {
    my ( $class, $args, $selectField, $value, @fields ) = splice @_;
    $value = quotemeta($value);
    $value =~ s/\\\*/\.\*/g;
    $value = qr/^$value$/;
    my %res = ();
    $class->get_key_from_all_sessions(
        $args,
        sub {
            my $entry = shift;
            my $id    = shift;
            return undef unless ( $entry->{$selectField} =~ $value );
            if (@fields) {
                $res{$id}->{$_} = $entry->{$_} foreach (@fields);
            }
            else {
                $res{$id} = $entry;
            }
            undef;
        }
    );
    return \%res;
}

1;

