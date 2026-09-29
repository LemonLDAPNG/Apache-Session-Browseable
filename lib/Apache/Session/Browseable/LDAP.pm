package Apache::Session::Browseable::LDAP;

use strict;

use Apache::Session;
use Apache::Session::Lock::Null;
use Apache::Session::Browseable::Store::LDAP;
use Apache::Session::Generate::SHA256;
use Apache::Session::Serialize::JSON;
use Apache::Session::Browseable::_common;
use Net::LDAP::Constant qw(LDAP_CONTROL_PAGED);
use Net::LDAP::Control::Paged;
use Net::LDAP::Util qw(escape_filter_value);

our $VERSION = '1.4.0';
our @ISA     = qw(Apache::Session Apache::Session::Browseable::_common);

# Page size of searches that may return many entries
our $PageSize = 500;

my $numRe = qr/^(-?)([0-9]+)(?:\.([0-9]+))?\z/;

sub populate {
    my $self = shift;

    $self->{object_store} = new Apache::Session::Browseable::Store::LDAP $self;
    $self->{lock_manager} = new Apache::Session::Lock::Null $self;
    $self->{generate}     = \&Apache::Session::Generate::SHA256::generate;
    $self->{validate}     = \&Apache::Session::Generate::SHA256::validate;
    $self->{serialize}    = \&Apache::Session::Serialize::JSON::serialize;
    $self->{unserialize}  = \&Apache::Session::Serialize::JSON::unserialize;

    return $self;
}

sub unserialize {
    my $session = shift;
    my $tmp     = { serialized => $session };
    Apache::Session::Serialize::JSON::unserialize($tmp);
    return $tmp->{data};
}

sub searchOn {
    my ( $class, $args, $selectField, $value, @fields ) = @_;

    my $index =
      ref( $args->{Index} ) ? $args->{Index} : [ split /\s+/, $args->{Index} ];
    if ( grep { $_ eq $selectField } @$index ) {
        ( $selectField, $value ) = escape_filter_value( $selectField, $value );
        return $class->_query( $args, $selectField, $value, @fields );
    }
    else {
        return $class->SUPER::searchOn( $args, $selectField, $value, @fields );
    }
}

sub searchOnExpr {
    my ( $class, $args, $selectField, $value, @fields ) = @_;

    my $index =
      ref( $args->{Index} ) ? $args->{Index} : [ split /\s+/, $args->{Index} ];
    if ( grep { $_ eq $selectField } @$index ) {
        ( $selectField, $value ) = escape_filter_value( $selectField, $value );
        $value =~ s/\\2a/\*/gi;
        return $class->_query( $args, $selectField, $value, @fields );
    }
    else {
        return $class->SUPER::searchOn( $args, $selectField, $value, @fields );
    }
}

sub searchLt {
    my $class = shift;
    return $class->_searchCmp( -1, @_ );
}

sub searchGt {
    my $class = shift;
    return $class->_searchCmp( 1, @_ );
}

# The index attribute has no ordering rule and a substring filter can't bound
# the length of a number, so the index only restricts the search to sessions
# having the field. Values are compared in Perl; sessions without the field or
# where it isn't a number are skipped. LDAP errors return an empty result:
# Lemonldap::NG purge doesn't catch them.
sub _searchCmp {
    my ( $class, $sign, $args, $selectField, $value, @fields ) = @_;
    my $name = 'search' . ( $sign < 0 ? 'Lt' : 'Gt' );
    $value =~ s/^\s+|\s+$//g if ( defined $value );
    unless ( defined $value and $value =~ $numRe ) {
        print STDERR "$name: value must be a number\n";
        return {};
    }
    $class->_defaults($args);

    my $filter =
        $class->_fieldIsIndexed( $args, $selectField )
      ? $class->_presenceFilter( $args, $selectField )
      : "($args->{ldapAttributeId}=*)";
    my %res = ();
    my $ldap =
      eval { Apache::Session::Browseable::Store::LDAP->fromArgs($args)->ldap };
    unless ($ldap) {
        print STDERR "$name: unable to connect: $@\n";
        return {};
    }
    my $msg = $class->_pagedSearch(
        $ldap,
        sub {
            my $entry = shift;
            my $id    = $entry->get_value( $args->{ldapAttributeId} ) or return;
            my $tmp   = $entry->get_value( $args->{ldapAttributeContent} );
            return unless $tmp;
            eval { $tmp = unserialize($tmp); };
            return if $@;
            my $cmp = $class->_cmpNum( $tmp->{$selectField}, $value );
            return unless ( defined $cmp and $cmp == $sign );

            if (@fields) {
                $res{$id}->{$_} = $tmp->{$_} foreach (@fields);
            }
            else {
                $res{$id} = $tmp;
            }
        },
        base   => $args->{ldapConfBase},
        scope  => 'one',
        filter => "(&(objectClass=$args->{ldapObjectClass})$filter)",
        attrs  => [ $args->{ldapAttributeId}, $args->{ldapAttributeContent} ],
    );
    $ldap->unbind();
    $ldap->disconnect();
    if ($msg) {
        print STDERR "$name: LDAP error "
          . $msg->code . ': '
          . $msg->error . "\n";
        return {};
    }

    return \%res;
}

sub _query {
    my ( $class, $args, $selectField, $value, @fields ) = @_;
    my %res = ();
    $args->{ldapObjectClass}      ||= 'applicationProcess';
    $args->{ldapAttributeId}      ||= 'cn';
    $args->{ldapAttributeContent} ||= 'description';
    $args->{ldapAttributeIndex}   ||= 'ou';

    my $obj  = Apache::Session::Browseable::Store::LDAP->fromArgs($args);
    my $ldap = $obj->ldap();
    my $msg  = $ldap->search(
        base   => $args->{ldapConfBase},
        scope  => 'one',
        filter => "(&(objectClass="
          . $args->{ldapObjectClass} . ")("
          . $args->{ldapAttributeIndex}
          . "=${selectField}_$value))",
        attrs => [ $args->{ldapAttributeContent}, $args->{ldapAttributeId} ],
    );
    $ldap->unbind();
    $ldap->disconnect();

    if ( $msg->code ) {
        $obj->logError($msg);
    }
    else {
        foreach my $entry ( $msg->entries ) {
            my $id  = $entry->get_value( $args->{ldapAttributeId} ) or die;
            my $tmp = $entry->get_value( $args->{ldapAttributeContent} );
            next unless $tmp;
            eval { $tmp = unserialize($tmp); };
            next if ($@);
            if (@fields) {
                $res{$id}->{$_} = $tmp->{$_} foreach (@fields);
            }
            else {
                $res{$id} = $tmp;
            }
        }
    }

    return \%res;
}

sub get_key_from_all_sessions {
    my $class = shift;
    my $args  = shift;
    my $data  = shift;
    $args->{ldapObjectClass}      ||= 'applicationProcess';
    $args->{ldapAttributeId}      ||= 'cn';
    $args->{ldapAttributeContent} ||= 'description';
    $args->{ldapAttributeIndex}   ||= 'ou';

    my %res  = ();
    my $obj  = Apache::Session::Browseable::Store::LDAP->fromArgs($args);
    my $ldap = $obj->ldap();
    my $msg  = $ldap->search(
        base  => $args->{ldapConfBase},
        scope => 'one',

     # VERY STRANGE BUG ! With this filter, description isn't base64 encoded !!!
     #filter => '(objectClass=applicationProcess)',

        # Sessions without any indexed value have no index attribute
        filter => '(&(objectClass='
          . $args->{ldapObjectClass} . ')('
          . $args->{ldapAttributeId} . '=*))',
        attrs => [ $args->{ldapAttributeId}, $args->{ldapAttributeContent} ],
    );

    $ldap->unbind();
    $ldap->disconnect();
    if ( $msg->code ) {
        $obj->logError($msg);
    }
    else {
        foreach my $entry ( $msg->entries ) {
            my $id  = $entry->get_value( $args->{ldapAttributeId} ) or die;
            my $tmp = $entry->get_value( $args->{ldapAttributeContent} );
            next unless ($tmp);
            eval { $tmp = unserialize($tmp); };
            next if $@;
            if ( ref($data) eq 'CODE' ) {
                $res{$id} = &$data( $tmp, $id );
            }
            elsif ($data) {
                $data = [$data] unless ( ref($data) );
                $res{$id}->{$_} = $tmp->{$_} foreach (@$data);
            }
            else {
                $res{$id} = $tmp;
            }
        }
    }

    return \%res;
}

sub _defaults {
    my ( $class, $args ) = @_;
    $args->{ldapObjectClass}      ||= 'applicationProcess';
    $args->{ldapAttributeId}      ||= 'cn';
    $args->{ldapAttributeContent} ||= 'description';
    $args->{ldapAttributeIndex}   ||= 'ou';
}

# Matches entries having an index value for $field. It may also match other
# fields whose name starts with "${field}_": callers check values in Perl
sub _presenceFilter {
    my ( $class, $args, $field ) = @_;
    return
      "($args->{ldapAttributeIndex}=" . escape_filter_value("${field}_") . '*)';
}

# Calls $cb on each entry, page by page to avoid server size limits. Returns
# the failed LDAP message, or nothing on success
sub _pagedSearch {
    my ( $class, $ldap, $cb, %search ) = @_;
    my $page = Net::LDAP::Control::Paged->new( size => $PageSize );
    while (1) {
        my $msg = $ldap->search( %search, control => [$page] );
        return $msg if $msg->code;
        $cb->($_) foreach ( $msg->entries );

        # Servers without paged results support return everything at once
        my ($resp) = $msg->control(LDAP_CONTROL_PAGED);
        return unless ( $resp and $resp->cookie );
        $page->cookie( $resp->cookie );
    }
}

# Exact comparison of two decimal numbers given as strings (no float
# rounding), surrounding spaces ignored: returns -1, 0 or 1, undef if one of
# them isn't a number
sub _cmpNum {
    my ( $class, @v ) = @_;
    foreach (@v) {
        return undef unless ( defined $_ and !ref $_ );
        s/^\s+|\s+$//g;
        return undef unless ( $_ =~ $numRe );
        my ( $sign, $int, $frac ) = ( $1 ? -1 : 1, $2, defined $3 ? $3 : '' );
        $int  =~ s/^0+//;
        $frac =~ s/0+\z//;
        $sign = 1 unless ( length $int or length $frac );
        $_    = [ $sign, $int, $frac ];
    }
    my ( $x, $y ) = @v;
    return $x->[0] <=> $y->[0] if ( $x->[0] != $y->[0] );
    my $cmp =
         length( $x->[1] ) <=> length( $y->[1] )
      || $x->[1] cmp $y->[1]
      || $x->[2] cmp $y->[2];
    return $x->[0] * $cmp;
}

1;

=pod

=head1 NAME

Apache::Session::Browseable::LDAP - An implementation of Apache::Session::LDAP

=head1 SYNOPSIS

  use Apache::Session::Browseable::LDAP;
  tie %hash, 'Apache::Session::Browseable::LDAP', $id, {
    ldapServer           => 'ldap://localhost:389',
    ldapConfBase         => 'dmdName=applications,dc=example,dc=com',
    ldapBindDN           => 'cn=admin,dc=example,dc=com',
    ldapBindPassword     => 'pass',
    Index                => 'uid ipAddr',
    ldapObjectClass      => 'applicationProcess',
    ldapAttributeId      => 'cn',
    ldapAttributeContent => 'description',
    ldapAttributeIndex   => 'ou',
    ldapVerify           => 'require',
    ldapCAFile           => '/etc/ssl/certs/ca-certificates.crt',
    ldapTimeout          => 10,
  };

=head1 DESCRIPTION

This module is an implementation of Apache::Session. It uses an LDAP directory
to store datas.

See L<Apache::Session::Browseable::Store::LDAP> for the available options.

Each session is an entry named C<ldapAttributeId=id,ldapConfBase> (default
objectClass C<applicationProcess>, available in the core schema). The session
is serialized in JSON into C<ldapAttributeContent>, and each field listed in
C<Index> and set in the session is stored as a C<field_value> value of
C<ldapAttributeIndex>. Fields whose value is empty or C<0> are not indexed.

The directory should index C<ldapAttributeIndex> for equality and substring
searches (OpenLDAP: C<index ou eq,sub>).

=head2 searchLt() and searchGt()

  # Refresh tokens not updated since 1 hour
  my $hash = Apache::Session::Browseable::LDAP->searchLt( $args,
      '_oidcRtUpdate', time - 3600 );
  my $hash = Apache::Session::Browseable::LDAP->searchGt( $args,
      '_utime', time - 3600, 'uid', 'ipAddr' );

Return sessions whose field is strictly lower (or greater) than the given
number, like searchOn(). Sessions without the field, or where it isn't a
number, are skipped. The value must be a decimal number
(C</^-?[0-9]+(?:\.[0-9]+)?$/>), otherwise an empty result is returned with a
warning. LDAP errors also return an empty result with a warning.

The index attribute has no ordering matching rule, and substring filters
can't bound the length of a number, so the directory can't select the lower
values. When the field is indexed, only sessions having it are read; otherwise
all sessions are read. Numbers are then compared in Perl. Lemonldap::NG purge
calls searchLt() on C<_oidcRtUpdate> when a refresh token activity timeout is
set: add it to C<Index>.

When the field is indexed, sessions are found through their index values:
sessions whose value is C<0> or empty, or written before the field was added
to C<Index>, are missed until they are rewritten.

searchLt() and searchGt() use the paged results control. With OpenLDAP, if
the bind DN isn't the rootdn, allow it to read all sessions, for example with
C<limits dn.exact="E<lt>bind DNE<gt>" size=unlimited> (this covers paged and
unpaged searches).

=head1 COPYRIGHT AND LICENSE

=encoding utf8

=over

=item 2009-2025 by Xavier Guimard

=item 2013-2025 by Clément Oudot

=item 2019-2025 by Maxime Besson

=item 2013-2025 by Worteks

=item 2023-2025 by Linagora

=back

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.0 or,
at your option, any later version of Perl 5 you may have available.

=head1 SEE ALSO

L<Apache::Session>

=cut
