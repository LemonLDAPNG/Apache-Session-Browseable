package Apache::Session::Browseable::Store::Oracle;

use strict;

use Apache::Session::Browseable::Store::DBI;
use Apache::Session::Store::Oracle;

our @ISA =
  qw(Apache::Session::Browseable::Store::DBI Apache::Session::Store::Oracle);
our $VERSION = '0.1';

1;

