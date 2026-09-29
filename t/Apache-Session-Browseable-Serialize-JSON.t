use strict;
use warnings;
use Test::More;
use Storable     qw(freeze nfreeze);
use MIME::Base64 qw(encode_base64 decode_base64);

use_ok('Apache::Session::Serialize::JSON');

sub unser { Apache::Session::Serialize::JSON::_unserialize(@_) }

my $latin = "\x{c9}lodie";            # Latin-1 range
my $wide  = "\x{c9}lodie \x{3a9}";    # beyond Latin-1

sub bytes { my $s = shift; utf8::encode($s); $s }

# serialize() produces characters
my $session = { data => { cn => $wide, sn => $latin } };
Apache::Session::Serialize::JSON::serialize($session);
my $chars = $session->{serialized};
ok( utf8::is_utf8($chars), 'serialize produces characters' );
$session = { data => { sn => $latin } };
is(
    Apache::Session::Serialize::JSON::serialize($session),
    $session->{serialized},
    'serialize returns serialized data'
);
ok(
    utf8::is_utf8( $session->{serialized} ),
    'serialize produces characters with Latin-1 data'
);

# Characters
is_deeply( unser($chars), { cn => $wide, sn => $latin }, 'Characters' );
is_deeply( unser('{"cn":"dwho"}'), { cn => 'dwho' },     'ASCII' );
my $up = qq'{"cn":"$latin"}';
utf8::upgrade($up);
is_deeply( unser($up), { cn => $latin }, 'Upgraded Latin-1 characters' );
is_deeply(
    unser('{"cn":"\u00c9lodie \u03a9"}'),
    { cn => $wide },
    'Escaped characters'
);

# UTF-8 bytes (MySQL json column, files,...)
my $utf8 = bytes($chars);
ok( !utf8::is_utf8($utf8), 'UTF-8 bytes are not flagged' );
is_deeply( unser($utf8), { cn => $wide, sn => $latin }, 'UTF-8 bytes' );
is_deeply(
    unser( bytes(qq'{"sn":"$latin"}') ),
    { sn => $latin },
    'UTF-8 bytes in Latin-1 range'
);
is( unser( bytes(qq'"$wide"') ), $wide, 'UTF-8 bytes, not a reference' );

# Latin-1 bytes (not valid UTF-8)
my $l1 = qq'{"sn":"$latin"}';
utf8::downgrade($l1);
is_deeply( unser($l1), { sn => $latin }, 'Latin-1 bytes' );
is_deeply(
    unser(qq'{"sn":"\xe9t\xe9","cn":"\xc3\xa9"}'),
    { sn => "\xe9t\xe9", cn => "\xc3\xa9" },
    'Latin-1 bytes, partly valid UTF-8'
);
is_deeply(
    unser(qq'{"cn":"\xc3\xa9"}'),
    { cn => "\x{e9}" },
    'Bytes valid as UTF-8 are read as UTF-8'
);

# unserialize()
$session = { serialized => $utf8 };
Apache::Session::Serialize::JSON::unserialize($session);
is_deeply(
    $session->{data},
    { cn => $wide, sn => $latin },
    'unserialize with UTF-8 bytes'
);
$session = { serialized => 'null' };
eval { Apache::Session::Serialize::JSON::unserialize($session) };
like( $@, qr/could not be unserialized/, 'unserialize dies on null' );

# unserializeLatin1() never decodes UTF-8
$session = { serialized => qq'{"cn":"\xc3\xa9"}' };
Apache::Session::Serialize::JSON::unserializeLatin1($session);
is( $session->{data}->{cn}, "\xc3\xa9", 'unserializeLatin1 with bytes' );
$session = { serialized => $chars };
Apache::Session::Serialize::JSON::unserializeLatin1($session);
is_deeply(
    $session->{data},
    { cn => $wide, sn => $latin },
    'unserializeLatin1 with characters'
);
$session = { serialized => encode_base64( freeze( { a => 1 } ) ) };
Apache::Session::Serialize::JSON::unserializeLatin1( $session,
    sub { Storable::thaw( decode_base64( $_[0] ) ) } );
is_deeply( $session->{data}, { a => 1 }, 'unserializeLatin1 fallback' );

# Storable fallback
my $data = { cn => $wide, sn => $latin, n => [ 1 .. 200 ] };
like( freeze($data), qr/[\x80-\xff]/, 'Storable data contains high bytes' );
is_deeply( unser( freeze($data) ),  $data, 'Storable fallback' );
is_deeply( unser( nfreeze($data) ), $data, 'Storable fallback (nfreeze)' );
my $next = sub { Storable::thaw( decode_base64( $_[0] ) ) };
is_deeply( unser( encode_base64( freeze($data) ), $next ),
    $data, 'Custom fallback' );
is_deeply( unser( "\xff\xfe", sub { 'next' } ),
    'next', 'Fallback called on invalid data with high bytes' );
is( eval { unser("\xc3\xa9{") }, undef, 'Invalid data' );

done_testing();
