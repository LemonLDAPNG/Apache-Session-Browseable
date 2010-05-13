package Apache::Session::Browseable::Informix;

use strict;

use Apache::Session;
use Apache::Session::Lock::Null;
use Apache::Session::Browseable::Store::Informix;
use Apache::Session::Generate::MD5;
use Apache::Session::Serialize::Base64;

our $VERSION = '0.1';
our @ISA     = qw(Apache::Session::Browseable::DBI Apache::Session);

sub populate {
    my $self = shift;

    $self->{object_store} =
      new Apache::Session::Browseable::Store::Informix $self;
    $self->{lock_manager} = new Apache::Session::Lock::Null $self;
    $self->{generate}     = \&Apache::Session::Generate::MD5::generate;
    $self->{validate}     = \&Apache::Session::Generate::MD5::validate;
    $self->{serialize}    = \&Apache::Session::Serialize::Base64::serialize;
    $self->{unserialize}  = \&Apache::Session::Serialize::Base64::unserialize;

    return $self;
}

1;

