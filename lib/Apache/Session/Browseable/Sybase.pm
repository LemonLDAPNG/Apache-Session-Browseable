package Apache::Session::Browseable::Sybase;

use strict;

use Apache::Session;
use Apache::Session::Lock::Null;
use Apache::Session::Browseable::Store::Sybase;
use Apache::Session::Generate::MD5;
use Apache::Session::Serialize::Sybase;

our $VERSION = '0.1';
our @ISA     = qw(Apache::Session::Browseable::DBI Apache::Session);

sub populate {
    my $self = shift;

    $self->{object_store} =
      new Apache::Session::Browseable::Store::Sybase $self;
    $self->{lock_manager} = new Apache::Session::Lock::Null $self;
    $self->{generate}     = \&Apache::Session::Generate::MD5::generate;
    $self->{validate}     = \&Apache::Session::Generate::MD5::validate;
    $self->{serialize}    = \&Apache::Session::Serialize::Sybase::serialize;
    $self->{unserialize}  = \&Apache::Session::Serialize::Sybase::unserialize;

    return $self;
}

1;

