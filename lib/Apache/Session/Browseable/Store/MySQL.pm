package Apache::Session::Browseable::Store::MySQL;

use strict;

use Apache::Session::Browseable::Store::DBI;
use Apache::Session::Store::MySQL;

our @ISA =
  qw(Apache::Session::Browseable::Store::DBI Apache::Session::Store::MySQL);
our $VERSION = '0.1';

1;

