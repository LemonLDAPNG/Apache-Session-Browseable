package Apache::Session::Browseable::Informix;

use strict;

use Apache::Session;
use Apache::Session::Lock::Null;
use Apache::Session::Browseable::Store::Informix;
use Apache::Session::Generate::MD5;
use Apache::Session::Serialize::Base64;
use Apache::Session::Browseable::DBI;

our $VERSION = '0.8';
our @ISA     = qw(Apache::Session::Browseable::DBI Apache::Session);

*serialize   = \&Apache::Session::Serialize::Base64::serialize;
*unserialize = \&Apache::Session::Serialize::Base64::unserialize;

sub populate {
    my $self = shift;

    $self->{object_store} =
      new Apache::Session::Browseable::Store::Informix $self;
    $self->{lock_manager} = new Apache::Session::Lock::Null $self;
    $self->{generate}     = \&Apache::Session::Generate::MD5::generate;
    $self->{validate}     = \&Apache::Session::Generate::MD5::validate;
    $self->{serialize}    = \&serialize;
    $self->{unserialize}  = \&unserialize;

    return $self;
}

1;

