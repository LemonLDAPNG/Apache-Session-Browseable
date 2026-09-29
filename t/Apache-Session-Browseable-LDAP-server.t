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
        my $res = $ldap->search(
            base   => $container,
            scope  => 'one',
            filter => '(objectClass=*)',
            attrs  => ['1.1'],
        );
        $ldap->delete( $_->dn ) foreach $res->entries;
        $ldap->delete($container);
    }
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

done_testing();
