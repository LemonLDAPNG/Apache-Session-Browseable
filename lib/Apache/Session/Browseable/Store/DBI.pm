package Apache::Session::Browseable::Store::DBI;

use strict;
use Apache::Session::Store::DBI;
our @ISA     = qw(Apache::Session::Store::DBI);
our $VERSION = 1.3.11;

# Connection reuse (default): returns a handle cached by DBI->connect_cached() (which
# pings it and reconnects if needed), opened with the attributes $attr that
# the store uses without this option. Returns undef if the store is already
# connected, if "noreuse" is set or if a Handle is given.
#
# Stores don't disconnect a handle they didn't open, so a transaction that
# the store doesn't commit (AutoCommit off, Commit not set or commit failure)
# would stay open, with its locks, on the shared handle: it is rolled back
# when the store is destroyed, after its own DESTROY (as disconnect did)
sub _reusedHandle {
    my ( $self, $args, $datasource, $username, $password, $attr ) = @_;
    return undef
      if ( defined $self->{dbh} or $args->{noreuse} or exists $args->{Handle} );
    my $dbh = DBI->connect_cached( $datasource, $username, $password, $attr )
      || die $DBI::errstr;
    $self->{reuse_rollback} =
      bless \$dbh, 'Apache::Session::Browseable::Store::DBI::Rollback'
      unless ( $dbh->{AutoCommit} );
    return $dbh;
}

# connection() of stores whose parent class $class (an Apache::Session::Store
# class) opens a connection with the attributes $attr and uses the Handle
# argument as is
sub _connection {
    my ( $self, $session, $class, $attr ) = @_;
    my $args    = $session->{args};
    my $connect = $class->can('connection');
    my @credentials;
    {
        no strict 'refs';
        @credentials = map { $args->{$_} || ${"${class}::$_"} }
          qw(DataSource UserName Password);
    }
    if ( my $dbh = $self->_reusedHandle( $args, @credentials, $attr ) ) {
        local $args->{Handle} = $dbh;
        return $self->$connect($session);
    }
    return $self->$connect($session);
}

sub insert {
    my ( $self, $session ) = @_;

    $self->connection($session);

    local $self->{dbh}->{RaiseError} = 1;

    my $index =
      ref( $session->{args}->{Index} )
      ? $session->{args}->{Index}
      : [ split /\s+/, $session->{args}->{Index} ];

    $self->{insert_sth} //=
      $self->{dbh}->prepare_cached( "INSERT INTO $self->{table_name} ("
          . join( ',', 'id', 'a_session', map { s/'/''/g; $_ } @$index )
          . ') VALUES ('
          . join( ',', ('?') x ( 2 + @$index ) )
          . ')' );

    $self->{insert_sth}->bind_param( 1, $session->{data}->{_session_id} );
    $self->{insert_sth}->bind_param( 2, $session->{serialized} );
    my $i = 3;
    foreach my $f (@$index) {
        $self->{insert_sth}->bind_param( $i, $session->{data}->{$f} );
        $i++;
    }

    $self->{insert_sth}->execute;

    $self->{insert_sth}->finish;
}

sub update {
    my $self    = shift;
    my $session = shift;

    $self->connection($session);

    local $self->{dbh}->{RaiseError} = 1;

    my $index =
      ref( $session->{args}->{Index} )
      ? $session->{args}->{Index}
      : [ split /\s+/, $session->{args}->{Index} ];

    if ( !defined $self->{update_sth} ) {
        $self->{update_sth} =
          $self->{dbh}->prepare_cached( "UPDATE $self->{table_name} SET "
              . join( ' = ?, ', 'a_session', @$index )
              . ' = ? WHERE id = ?' );
    }

    $self->{update_sth}->bind_param( 1, $session->{serialized} );
    my $i = 2;
    foreach my $f (@$index) {
        $self->{update_sth}->bind_param( $i, $session->{data}->{$f} );
        $i++;
    }
    $self->{update_sth}->bind_param( $i, $session->{data}->{_session_id} );

    $self->{update_sth}->execute;

    $self->{update_sth}->finish;
}

package Apache::Session::Browseable::Store::DBI::Rollback;

# Ends the transaction left by a store using a reused handle (no-op if the
# store committed it)
sub DESTROY {
    my $dbh = ${ $_[0] };
    local $@;
    eval { $dbh->rollback } if ( $dbh->{Active} and !$dbh->{AutoCommit} );
}

1;
