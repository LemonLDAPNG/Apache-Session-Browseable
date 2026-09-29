use Test::More;
use strict;

# Tests against a real directory. Example with a local OpenLDAP:
#   LDAP_URL=ldap://127.0.0.1:389 LDAP_BINDDN=cn=admin,dc=example,dc=com \
#   LDAP_BINDPW=secret LDAP_BASE=dc=example,dc=com prove -l t/
# The tests run in a temporary container created under LDAP_BASE.

plan skip_all => 'Set LDAP_URL and LDAP_BASE to run LDAP server tests'
  unless ( $ENV{LDAP_URL} and $ENV{LDAP_BASE} );
plan skip_all => 'Optional modules (Net::LDAP) not installed'
  unless eval { require Net::LDAP; };

my $ldap = Net::LDAP->new( $ENV{LDAP_URL}, onerror => undef )
  or plan skip_all => "Unable to connect to $ENV{LDAP_URL}: $@";
my $msg =
    $ENV{LDAP_BINDDN}
  ? $ldap->bind( $ENV{LDAP_BINDDN}, password => $ENV{LDAP_BINDPW} )
  : $ldap->bind;
plan skip_all => 'Bind failed: ' . $msg->error if $msg->code;

my $package = 'Apache::Session::Browseable::LDAP';
use_ok($package);

my $container = "ou=asb-test-$$,$ENV{LDAP_BASE}";
my $args      = {
    ldapServer       => $ENV{LDAP_URL},
    ldapConfBase     => $container,
    ldapBindDN       => $ENV{LDAP_BINDDN},
    ldapBindPassword => $ENV{LDAP_BINDPW},
    Index            => 'uid',
};

$msg = $ldap->add(
    $container,
    attrs => [
        objectClass => 'organizationalUnit',
        ou          => "asb-test-$$",
    ]
);
BAIL_OUT( "Unable to create $container: " . $msg->error ) if $msg->code;
my $created = 1;

END {
    if ($created) {
        clean();
        $ldap->delete($container);
    }
}

# Remove all sessions
sub clean {
    my $res = $ldap->search(
        base   => $container,
        scope  => 'one',
        filter => '(objectClass=*)',
        attrs  => ['1.1'],
    );
    $ldap->delete( $_->dn ) foreach $res->entries;
}

sub ids {
    return [ sort keys %{ $_[0] } ];
}

# Runs $sub with STDERR captured, returns what was printed
sub stderrOf {
    my ($sub) = @_;
    my $buf = '';
    open my $saved, '>&', \*STDERR or die $!;
    close STDERR;
    open STDERR, '>', \$buf or die $!;
    eval { $sub->() };
    close STDERR;
    open STDERR, '>&', $saved or die $!;
    die $@ if $@;
    return $buf;
}

sub newSession {
    my ( $data, $a ) = @_;
    my %h;
    tie %h, $package, undef, ( $a || $args );
    $h{$_} = $data->{$_} foreach keys %$data;
    my $id = $h{_session_id};
    untie %h;
    return $id;
}

# get_key_from_all_sessions() must see sessions without any indexed value
# (#38)
my $idx   = newSession( { uid => 'dwho' } );
my $noIdx = newSession( { foo => 'bar' } );
my $all   = $package->get_key_from_all_sessions($args);
is_deeply(
    [ sort keys %$all ],
    [ sort ( $idx, $noIdx ) ],
    'get_key_from_all_sessions: sessions with and without index'
);
is( $all->{$noIdx}->{foo}, 'bar', 'Session without index: data' );
$all = $package->get_key_from_all_sessions( $args, 'foo' );
is_deeply( $all->{$noIdx}, { foo => 'bar' }, 'Field extraction' );

# searchLt() / searchGt()
clean();
$args->{Index} = 'uid _session_kind _oidcRtUpdate';
my %s = (
    short  => newSession( { uid => 'short',  _oidcRtUpdate => 99 } ),
    low    => newSession( { uid => 'low',    _oidcRtUpdate => 998 } ),
    equal  => newSession( { uid => 'equal',  _oidcRtUpdate => 1000 } ),
    high   => newSession( { uid => 'high',   _oidcRtUpdate => 1001 } ),
    long   => newSession( { uid => 'long',   _oidcRtUpdate => 10000 } ),
    dec    => newSession( { uid => 'dec',    _oidcRtUpdate => '999.5' } ),
    nan    => newSession( { uid => 'nan',    _oidcRtUpdate => 'abc' } ),
    spaced => newSession( { uid => 'spaced', _oidcRtUpdate => ' 999 ' } ),
    none   => newSession( { uid => 'none' } ),
    unindx => newSession( { uid => 'unindx', counter => 5 } ),
);
my %name = reverse %s;

sub names {
    [ sort map { $name{$_} } keys %{ $_[0] } ]
}

{
    # Also check that the paged search loops
    local $Apache::Session::Browseable::LDAP::PageSize = 2;
    my $res = $package->searchLt( $args, '_oidcRtUpdate', 1000 );
    is_deeply(
        names($res),
        [qw(dec low short spaced)],
        'searchLt: lower values of any length, not equal/missing/NaN'
    );
    is( $res->{ $s{low} }->{uid}, 'low', 'searchLt: whole session' );
}
my $res = $package->searchLt( $args, '_oidcRtUpdate', 1000, 'uid' );
is_deeply(
    $res->{ $s{short} },
    { uid => 'short' },
    'searchLt: requested fields only'
);
is_deeply( names( $package->searchGt( $args, '_oidcRtUpdate', 1000 ) ),
    [qw(high long)], 'searchGt: greater values, not equal' );
is_deeply( names( $package->searchLt( $args, '_oidcRtUpdate', '999.5' ) ),
    [qw(low short spaced)], 'searchLt: decimal value' );
is_deeply( names( $package->searchLt( $args, '_oidcRtUpdate', ' 100 ' ) ),
    ['short'], 'searchLt: value with spaces' );
is_deeply( names( $package->searchLt( $args, '_oidcRtUpdate', -1 ) ),
    [], 'searchLt: negative value' );
is_deeply( names( $package->searchLt( $args, 'counter', 6 ) ),
    ['unindx'], 'searchLt: non indexed field' );
is_deeply( names( $package->searchGt( $args, 'counter', 5 ) ),
    [], 'searchGt: non indexed field, equal' );

foreach my $bad ( 'abc', '1e3', '', undef, '10; (cn=*)' ) {
    my $r;
    my $err =
      stderrOf(
        sub { $r = $package->searchLt( $args, '_oidcRtUpdate', $bad ) } );
    my $d = defined $bad ? "'$bad'" : 'undef';
    is_deeply( $r, {}, "searchLt: invalid value $d" );
    like( $err, qr/searchLt: value must be a number/, "... warns ($d)" );
}

# Like LLNG purge: refresh tokens not updated since 1 hour
clean();
my $now = time;
my $old = newSession(
    {
        _session_kind => 'OIDCI',
        _type         => 'refresh_token',
        _oidcRtUpdate => $now - 7200,
    }
);
my $recent = newSession(
    {
        _session_kind => 'OIDCI',
        _type         => 'refresh_token',
        _oidcRtUpdate => $now - 60,
    }
);
my $sso = newSession( { _session_kind => 'SSO', _utime => $now - 7200 } );
$res = $package->searchLt( $args, '_oidcRtUpdate', $now - 3600 );
is_deeply( ids($res), [$old], 'Purge-like searchLt: only the old token' );
is( $res->{$old}->{_type}, 'refresh_token', 'Purge-like searchLt: session' );

# LDAP errors: empty result and a warning, no die (LLNG purge doesn't catch)
{
    no warnings 'redefine';
    my $orig = \&Net::LDAP::search;

    # Server size limit
    local *Net::LDAP::search = sub { $orig->( @_, sizelimit => 1 ) };
    my $err = stderrOf(
        sub { $res = $package->searchLt( $args, '_oidcRtUpdate', $now ) } );
    is_deeply( $res, {}, 'searchLt: size limit exceeded, empty result' );
    like( $err, qr/searchLt: LDAP error 4/, '... and a warning' );
}
my $err = stderrOf(
    sub {
        $res =
          $package->searchGt( { %$args, ldapServer => 'ldap://127.0.0.1:1' },
            '_oidcRtUpdate', 1 );
    }
);
is_deeply( $res, {}, 'searchGt: connection error, empty result' );
like( $err, qr/searchGt: unable to connect/, '... and a warning' );

done_testing();
