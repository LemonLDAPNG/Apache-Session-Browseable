package Apache::Session::Browseable::DBI;

use strict;

use DBI;
use Apache::Session;

our $VERSION = '0.2';
our @ISA     = qw(Apache::Session);

sub searchOn {
    my ( $class, $args, $selectField, $value, @fields ) = @_;

    my %res = ();
    my $index =
      ref( $args->{Index} ) ? $args->{Index} : [ split /\s+/, $args->{Index} ];
    if ( grep { $_ eq $selectField } @$index ) {
        my $dbh        = $class->_classDbh($args);
        my $table_name = $args->{TableName}
          || $Apache::Session::Store::DBI::TableName;
        my $sth = $dbh->prepare(
            "SELECT id,a_session from $table_name where $selectField='$value'");
        $sth->execute;
        while ( my @row = $sth->fetchrow_array ) {
            my $sub = "$class::unserialize";
            my $tmp = &$sub( { serialized => $row[1] } );
            if (@fields) {
                $res{ $row[0] }->{$_} = $tmp->{$_} foreach (@fields);
            }
            else {
                $res{ $row[0] } = $tmp;
            }
        }
    }
    else {
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
    my $sth = $dbh->prepare_cached("SELECT id,a_session from $table_name");
    $sth->execute;
    my %res;
    while ( my @row = $sth->fetchrow_array ) {
        my $sub = "$class::unserialize";
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

