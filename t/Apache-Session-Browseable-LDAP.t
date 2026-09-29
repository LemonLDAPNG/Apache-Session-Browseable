use Test::More;

plan skip_all => "Optional modules (Net::LDAP) not installed"
  unless eval {
      require Net::LDAP;
  };

plan tests => 61;

$package = 'Apache::Session::Browseable::Store::LDAP';

use_ok($package);
ok( !$INC{'IO/Socket/Timeout.pm'}, 'IO::Socket::Timeout not loaded' );

# fromArgs
my $args  = { ldapServer => 'ldap://localhost' };
my $store = $package->fromArgs($args);
isa_ok( $store, $package );
is( $store->{args}, $args, 'fromArgs keeps args' );

# _parseServers
sub parse {
    return $package->fromArgs( { ldapServer => shift, @_ } )->_parseServers;
}

my @s = parse('ldap://localhost');
is( $s[0]->{server},   'ldap://localhost', 'plain ldap: server' );
is( $s[0]->{startTls}, 0,                  'plain ldap: no StartTLS' );
is_deeply( $s[0]->{tlsParams}, { verify => 'require' }, 'default verify' );

@s = parse('ldaps://ldap.example.com?verify=none');
is( $s[0]->{server}, 'ldaps://ldap.example.com', 'ldaps without slash' );
is( $s[0]->{tlsParams}->{verify}, 'none',        'verify=none' );

@s = parse('ldaps://host:636?cafile=/etc/ca.pem');
is( $s[0]->{server},              'ldaps://host:636', 'ldaps with port' );
is( $s[0]->{tlsParams}->{cafile}, '/etc/ca.pem',      'cafile' );

@s = parse('ldaps://host/?cafile=/a&verify=optional');
is( $s[0]->{server}, 'ldaps://host', 'ldaps with slash' );
is_deeply(
    $s[0]->{tlsParams},
    { cafile => '/a', verify => 'optional' },
    'several params'
);

@s = parse('ldap+tls://a/?cafile=/ca.pem ldaps://b');
is( scalar @s,                    2,           'two servers' );
is( $s[0]->{server},              'a',         'ldap+tls: host' );
is( $s[0]->{startTls},            1,           'ldap+tls: StartTLS' );
is( $s[0]->{tlsParams}->{cafile}, '/ca.pem',   'ldap+tls: cafile' );
is( $s[1]->{server},              'ldaps://b', 'second server' );
is( $s[1]->{startTls},            0,           'second: no StartTLS' );
ok( !exists $s[1]->{tlsParams}->{cafile}, 'second: no cafile' );

@s = parse( 'ldaps://b', ldapCAFile => '/global.pem' );
is( $s[0]->{tlsParams}->{cafile}, '/global.pem', 'global cafile' );

@s = parse('ldaps://host/?onerror=die&keepalive=0&verify=none');
is_deeply( $s[0]->{tlsParams}, { verify => 'none' }, 'non-TLS keys filtered' );

@s = parse(
    'ldaps://h1/?verify=none&cafile=/url.pem ldaps://h2',
    ldapVerify     => 'optional',
    ldapCAFile     => '/g.pem',
    ldapClientCert => '/cert.pem',
);
is_deeply(
    $s[0]->{tlsParams},
    { verify => 'none', cafile => '/url.pem', clientcert => '/cert.pem' },
    'URL params override globals'
);
is_deeply(
    $s[1]->{tlsParams},
    { verify => 'optional', cafile => '/g.pem', clientcert => '/cert.pem' },
    'globals applied'
);

# _bind
{

    package MockSocket;
    sub new { bless { ssl => $_[1] }, $_[0] }
    sub isa { $_[1] eq 'IO::Socket::SSL' ? $_[0]->{ssl} : 0 }

    package MockLDAP;
    sub new    { bless { socket => MockSocket->new( $_[1] ) }, $_[0] }
    sub socket { $_[0]->{socket} }
    sub bind   { my $s = shift; $s->{args} = [@_]; return 'ok' }
}

sub bindArgs {
    my ( $ssl, $tls, %args ) = @_;
    my $ldap = MockLDAP->new($ssl);
    $package->fromArgs( \%args )->_bind( $ldap, $tls );
    return $ldap->{args};
}

my $r = bindArgs( 0, {}, ldapBindDN => 'cn=a', ldapBindPassword => '0' );
is_deeply( $r, [ 'cn=a', password => '0' ], 'simple bind, password "0"' );

$r = bindArgs( 1, { clientcert => '/c.pem' }, ldapBindDN => 'cn=a' );
is( $r->[0], 'cn=a', 'bind DN wins over client cert' );

SKIP: {
    skip 'Authen::SASL not installed', 3
      unless eval { require Authen::SASL };
    $r = bindArgs( 1, { clientcert => '/c.pem' } );
    is( $r->[0],            undef,      'SASL EXTERNAL: no DN' );
    is( $r->[1],            'sasl',     'SASL EXTERNAL: sasl arg' );
    is( $r->[2]->mechanism, 'EXTERNAL', 'SASL EXTERNAL mechanism' );
}

$r = bindArgs( 0, { clientcert => '/c.pem' } );
is_deeply( $r, [], 'no TLS + clientcert: anonymous' );

$r = bindArgs( 1, {} );
is_deeply( $r, [], 'TLS without clientcert: anonymous' );

$r = bindArgs( 0, {}, ldapBindDN => '' );
is_deeply( $r, [], 'empty DN: anonymous' );

ok( !$INC{'IO/Socket/Timeout.pm'}, 'IO::Socket::Timeout still not loaded' );

# Browseable::LDAP helpers (no server needed)
my $browseable = 'Apache::Session::Browseable::LDAP';
use_ok($browseable);

# _cmpNum: exact comparison of decimal strings
foreach (
    [ 1,                  2,                  -1 ],
    [ 10,                 9,                   1 ],
    [ 99,                 1000,               -1 ],
    [ '0010',             10,                  0 ],
    [ '7.000',            7,                   0 ],
    [ '-0',               '0.0',               0 ],
    [ -1,                  0,                 -1 ],
    [ -10,                -9,                 -1 ],
    [ '0.5',              '0.45',              1 ],
    [ '-0.5',             '-0.45',            -1 ],
    [ '999.5',            1000,               -1 ],
    [ 1790000000,         1790000001,         -1 ],
    [ '9007199254740993', '9007199254740992',  1 ],
    [ " 12\n",            ' 12 ',              0 ],
  )
{
    is( $browseable->_cmpNum( $_->[0], $_->[1] ),
        $_->[2], "_cmpNum($_->[0], $_->[1])" );
}
foreach ( 'abc', '', ' ', undef, '1e3', '1 2', '1.', '.5', '+1', '0x10', [1] ) {
    my $d = defined $_ ? "'$_'" : 'undef';
    ok( !defined $browseable->_cmpNum( $_, 1 ), "_cmpNum: $d isn't a number" );
}

# _presenceFilter escapes the field name
is( $browseable->_presenceFilter( { ldapAttributeIndex => 'ou' }, '_utime' ),
    '(ou=_utime_*)', '_presenceFilter' );
is(
    $browseable->_presenceFilter( { ldapAttributeIndex => 'ou' }, 'a*b(c)\\' ),
    '(ou=a\2ab\28c\29\5c_*)',
    '_presenceFilter: escaped field'
);
