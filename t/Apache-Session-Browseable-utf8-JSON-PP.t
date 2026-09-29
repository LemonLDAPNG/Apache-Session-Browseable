# Same tests as Apache-Session-Browseable-utf8.t with JSON::PP, which
# doesn't flag its result as UTF-8 when data holds only Latin-1 characters
BEGIN { $ENV{PERL_JSON_BACKEND} = 'JSON::PP' }

use strict;
use warnings;
use JSON;
use Test::More;

is( JSON->backend, 'JSON::Backend::PP', 'JSON::PP backend used' );
do './t/Apache-Session-Browseable-utf8.t';
die $@ if $@;
