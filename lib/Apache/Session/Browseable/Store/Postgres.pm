package Apache::Session::Browseable::Store::Postgres;

use strict;

use Apache::Session::Browseable::Store::DBI;
use Apache::Session::Store::Postgres;

our @ISA =
  qw(Apache::Session::Browseable::Store::DBI Apache::Session::Store::Postgres);
our $VERSION = '0.1';

1;

