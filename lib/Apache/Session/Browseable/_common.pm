package Apache::Session::Browseable::_common;

use strict;
use AutoLoader 'AUTOLOAD';

our $VERSION = '1.2.2';

# Number of sessions read per query by _forEachSession(). Values outside
# 1..1_000_000 fall back to the default (a huge value would break LIMIT)
our $BatchSize = 1000;

sub _tabInTab {
    my ( $class, $t1, $t2 ) = @_;

    # if no fields are required, return 0
    return 0 unless ( @$t1 and @$t2 );
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

# Digits are bounded: MySQL and Oracle reject out-of-range literals
sub _isNumber {
    my ( $class, $value ) = @_;
    return ( defined($value)
          and $value =~ /^-?[0-9]{1,20}(?:\.[0-9]{1,20})?\z/ );
}

# The operator of a comparison is inserted into SQL queries
sub _checkOp {
    my ( $class, $op ) = @_;
    die "_buildCompareExpression: invalid operator '"
      . ( defined $op ? $op : 'undef' ) . "'\n"
      unless ( defined $op and ( $op eq '<' or $op eq '>' ) );
    return $op;
}

# searchLt() and searchGt() values are also inserted into SQL queries. Return
# the value without surrounding spaces (kept by the Lemonldap::NG CLI), or
# undef if it isn't a number
sub _checkSearchValue {
    my ( $class, $op, $value ) = @_;
    $value =~ s/^\s+|\s+\z//g if ( defined $value );
    unless ( $class->_isNumber($value) ) {
        print STDERR 'search'
          . ( $op eq '<' ? 'Lt' : 'Gt' )
          . ": value must be a number\n";
        return undef;
    }
    return $value;
}

# Run the SQL query of searchLt() and searchGt(): the database may reject
# the comparison (a cast of a text column, for example). Print the error and
# return an empty result, as the Perl version does for non numeric values
sub _searchQuery {
    my ( $class, $op, $sub ) = @_;
    my $res = eval { $sub->() };
    if ($@) {
        my $err = $@;
        chomp $err;
        print STDERR 'search' . ( $op eq '<' ? 'Lt' : 'Gt' ) . ": $err\n";
        return {};
    }
    return $res;
}

# Perl version of searchLt() and searchGt(): read all sessions and keep those
# for which $test->( value of $selectField ) is true. As in SQL, a value that
# doesn't start with a number is 0: Perl would read "inf" or "nan" as
# Infinity and NaN
sub _searchByTest {
    my ( $class, $args, $selectField, $test, @fields ) = @_;
    my %res;
    $class->get_key_from_all_sessions(
        $args,
        sub {
            my ( $entry, $id ) = @_;
            my $v = $entry->{$selectField};
            $v = 0 if ( defined $v and $v !~ /^\s*-?[0-9]/ );
            return undef unless ( $test->($v) );
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

# Get the unserialize sub of a class (populate() may be inherited)
sub _unserializer {
    my ($class) = @_;
    my $p = $class->can('populate') or die "$class has no populate()\n";
    return $p->()->{unserialize};
}

# Call $sub->( $id, $serialized ) for each session. If the driver supports
# LIMIT, sessions are read by batches to avoid loading the whole table in
# memory. No server-side cursor here: $sub may reuse the database handle.
sub _forEachSession {
    my ( $class, $dbh, $table_name, $sub ) = @_;
    my ($limit) = ( $BatchSize // '' ) =~ /^\s*([1-9][0-9]*)\s*\z/;
    $limit = 1000 if ( !$limit or $limit > 1_000_000 );
    my $sql   = "SELECT id,a_session FROM $table_name";
    unless ( $dbh->{Driver}->{Name} =~ /^(?:Pg|mysql|MariaDB|SQLite)\z/ ) {
        my $sth = $dbh->prepare_cached($sql);
        $sth->execute;
        while ( my @row = $sth->fetchrow_array ) {
            $sub->(@row);
        }
        return;
    }

    # Not a single snapshot: rows inserted during the iteration with an id
    # lower than the current position are not visited (harmless for purge
    # and sessions explorer)
    my ( $last, $rows );
    do {
        my $sth =
          $dbh->prepare_cached( $sql
              . ( defined($last) ? ' WHERE id > ?' : '' )
              . " ORDER BY id LIMIT $limit" );
        $sth->execute( defined($last) ? ($last) : () );
        $rows = $sth->fetchall_arrayref;
        $sub->(@$_) foreach (@$rows);
        $last = $rows->[-1]->[0] if (@$rows);
    } while ( @$rows >= $limit );
    return;
}

# deleteIfLowerThan() thresholds are inserted into SQL queries, so they must
# be numbers
sub _checkThresholds {
    my ( $class, $rule ) = @_;
    return 1 unless ( ref($rule) eq 'HASH' );
    my $thresholds = $rule->{or} || $rule->{and};
    return 1 unless ( ref($thresholds) eq 'HASH' );
    foreach ( values %$thresholds ) {
        unless ( $class->_isNumber($_) ) {
            print STDERR "deleteIfLowerThan: threshold must be a number\n";
            return 0;
        }
    }
    return 1;
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

