package Apache::Session::Browseable::_common;

use strict;
use AutoLoader 'AUTOLOAD';

our $VERSION = '1.2.2';

# Number of sessions read per query by _forEachSession()
our $BatchSize = 1000;

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

# Get the unserialize sub of a class
sub _unserializer {
    my ($class) = @_;
    no strict 'refs';
    return &{"${class}::populate"}()->{unserialize};
}

# Call $sub->( $id, $serialized ) for each session. If the driver supports
# LIMIT, sessions are read by batches to avoid loading the whole table in
# memory. No server-side cursor here: $sub may reuse the database handle.
sub _forEachSession {
    my ( $class, $dbh, $table_name, $sub ) = @_;
    my $sql = "SELECT id,a_session FROM $table_name";
    unless ( $dbh->{Driver}->{Name} =~ /^(?:Pg|mysql|MariaDB|SQLite)\z/ ) {
        my $sth = $dbh->prepare_cached($sql);
        $sth->execute;
        while ( my @row = $sth->fetchrow_array ) {
            $sub->(@row);
        }
        return;
    }
    my ( $last, $rows );
    do {
        my $sth =
          $dbh->prepare_cached( $sql
              . ( defined($last) ? ' WHERE id > ?' : '' )
              . " ORDER BY id LIMIT $BatchSize" );
        $sth->execute( defined($last) ? ($last) : () );
        $rows = $sth->fetchall_arrayref;
        $sub->(@$_) foreach (@$rows);
        $last = $rows->[-1]->[0] if (@$rows);
    } while ( @$rows >= $BatchSize );
    return;
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

