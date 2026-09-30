package Apache::Session::Browseable::Store::MariaDBJSON;

use strict;

use DBI;
use Apache::Session::Store::MySQL;

# Only id and a_session are written: indexed fields are generated columns
our @ISA     = qw(Apache::Session::Store::MySQL);
our $VERSION = '1.3.20';

# DBD::MariaDB always uses utf8mb4. DBD::mysql only selects the connection
# charset from attributes given to connect(): setting mysql_enable_utf8 on an
# open handle leaves the default charset of the client library (latin1 on
# some builds)
sub connectAttributes {
    my ( $class, $datasource ) = @_;
    my %attr = ( RaiseError => 1, AutoCommit => 1 );
    $attr{mysql_enable_utf8mb4} = 1 if ( $datasource =~ /^dbi:mysql\b/i );
    return \%attr;
}

sub connection {
    my ( $self, $session ) = @_;
    my $args = $session->{args};

    # Same as Apache::Session::Store::MySQL, with the right connection
    # attributes
    unless ( defined $self->{dbh} or exists $args->{Handle} ) {
        my $datasource = $args->{DataSource}
          || $Apache::Session::Store::MySQL::DataSource;
        my $username = $args->{UserName}
          || $Apache::Session::Store::MySQL::UserName;
        my $password = $args->{Password}
          || $Apache::Session::Store::MySQL::Password;
        $self->{table_name} =
          $args->{TableName} || $Apache::Session::Store::DBI::TableName;
        $self->{dbh} =
          DBI->connect( $datasource, $username, $password,
            $self->connectAttributes($datasource) )
          || die $DBI::errstr;

        # If we open the connection, we close the connection
        $self->{disconnect} = 1;
        return;
    }
    $self->SUPER::connection($session);
}

1;
