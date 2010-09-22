package Apache::Session::Browseable::MySQL;

use strict;

use Apache::Session::Browseable::DBI;
use Apache::Session::Browseable::Store::MySQL;
use Apache::Session::Lock::Null;
use Apache::Session::Generate::MD5;
use Apache::Session::Serialize::Storable;

our $VERSION = '0.3';
our @ISA     = qw(Apache::Session::Browseable::DBI);

sub populate {
    my $self = shift;

    $self->{object_store} = new Apache::Session::Browseable::Store::MySQL $self;
    $self->{lock_manager} = new Apache::Session::Lock::Null $self;
    $self->{generate}     = \&Apache::Session::Generate::MD5::generate;
    $self->{validate}     = \&Apache::Session::Generate::MD5::validate;
    $self->{serialize}    = \&Apache::Session::Serialize::Storable::serialize;
    $self->{unserialize}  = \&Apache::Session::Serialize::Storable::unserialize;

    return $self;
}

1;

