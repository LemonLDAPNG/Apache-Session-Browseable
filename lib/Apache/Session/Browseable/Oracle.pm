package Apache::Session::Browseable::Oracle;

use strict;

use Apache::Session;
use Apache::Session::Lock::Null;
use Apache::Session::Browseable::Store::Oracle;
use Apache::Session::Generate::SHA256;
use Apache::Session::Serialize::JSON;
use Apache::Session::Browseable::DBI;

our $VERSION = '1.2.2';
our @ISA     = qw(Apache::Session::Browseable::DBI Apache::Session);

sub populate {
    my $self = shift;

    $self->{object_store} =
      new Apache::Session::Browseable::Store::Oracle $self;
    $self->{lock_manager} = new Apache::Session::Lock::Null $self;
    $self->{generate}     = \&Apache::Session::Generate::SHA256::generate;
    $self->{validate}     = \&Apache::Session::Generate::SHA256::validate;
    $self->{serialize}    = \&Apache::Session::Serialize::JSON::serialize;
    $self->{unserialize}  = \&Apache::Session::Serialize::JSON::unserialize;

    return $self;
}

# Index columns are double-quoted, see Apache::Session::Browseable::Store::Oracle
sub _quoteColumn {
    my ( $class, $dbh, $field ) = @_;
    return Apache::Session::Browseable::Store::Oracle->_quoteColumn($field);
}

# Oracle returns unquoted column names (id) in upper case and quoted ones
# (index columns) in their own case: read them in lower case, then restore
# the case of the requested fields. a_session (CLOB or LONG) is read up to
# LongReadLen bytes, as Apache::Session::Store::Oracle does
sub _classDbh {
    my ( $class, $args ) = @_;
    my $dbh = $class->SUPER::_classDbh($args);
    $dbh->{FetchHashKeyName} = 'NAME_lc';
    $dbh->{LongReadLen}      = $args->{LongReadLen} || 8 * 2**10;
    return $dbh;
}

sub searchOn {
    my $class = shift;
    my ( $args, $selectField, $value, @fields ) = @_;
    my $res = $class->SUPER::searchOn(@_);
    return $class->_restoreCase( $res, @fields );
}

sub searchOnExpr {
    my $class = shift;
    my ( $args, $selectField, $value, @fields ) = @_;
    my $res = $class->SUPER::searchOnExpr(@_);
    return $class->_restoreCase( $res, @fields );
}

sub get_key_from_all_sessions {
    my ( $class, $args, $data ) = @_;
    my $res = $class->SUPER::get_key_from_all_sessions( @_[ 1 .. $#_ ] );
    if ( defined $data and ref($data) ne 'CODE' ) {
        $class->_restoreCase( $res, ref($data) eq 'ARRAY' ? @$data : $data );
    }
    return $res;
}

1;

