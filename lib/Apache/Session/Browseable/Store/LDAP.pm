package Apache::Session::Browseable::Store::LDAP;

use strict;
use Net::LDAP;

our $VERSION = '0.1';

sub new {
    my $class = shift;
    return bless {}, $class;
}

sub insert {
    my $self    = shift;
    my $session = shift;
    $self->{args} = $session->{args};
    my $index =
      ref( $session->{args}->{Index} )
      ? $session->{args}->{Index}
      : [ split /\s+/, $session->{args}->{Index} ];
    my $id = $session->{data}->{_session_id};

    my $ou;
    foreach my $i (@$index) {
        my $t;
        next unless ( $t = $session->{data}->{$i} );
        push @$ou, "${i}_$t";
    }
    my $attrs = [
        objectClass => [ 'top', 'applicationProcess' ],
        cn          => $session->{data}->{_session_id},
        description => $session->{serialized},
    ];
    push @$attrs, ( ou => $ou ) if ($ou);

    my $msg = $self->ldap->add( "cn=$id," . $self->{args}->{ldapConfBase},
        attrs => $attrs, );
    $self->logError($msg) if ( $msg->code );
}

sub update {
    my $self    = shift;
    my $session = shift;
    $self->{args} = $session->{args};
    my $index =
      ref( $session->{args}->{Index} )
      ? $session->{args}->{Index}
      : [ split /\s+/, $session->{args}->{Index} ];
    my $id = $session->{data}->{_session_id};

    my $ou;
    foreach my $i (@$index) {
        my $t;
        next unless ( $t = $session->{data}->{$i} );
        push @$ou, "${i}_$t";
    }
    my $attrs = { description => $session->{serialized} };
    $attrs->{ou} = $ou if ($ou);

    my $msg = $self->ldap->modify(
        "cn=$session->{data}->{_session_id}," . $self->{args}->{ldapConfBase},
        replace => $attrs, );

    $self->logError($msg) if ( $msg->code );
}

sub materialize {
    my $self    = shift;
    my $session = shift;
    $self->{args} = $session->{args};

    my $msg = $self->ldap->search(
        base => "cn=$session->{data}->{_session_id},"
          . $self->{args}->{ldapConfBase},
        filter => '(objectClass=applicationProcess)',
        scope  => 'base',
        attrs  => ['description'],
    );

    $self->logError($msg) if ( $msg->code );

    eval {
        $session->{serialized} = $msg->shift_entry()->get_value('description');
    };

    if ( !defined $session->{serialized} ) {
        die "Object does not exist in data store";
    }
}

sub remove {
    my $self    = shift;
    my $session = shift;
    $self->{args} = $session->{args};

    $self->ldap->delete(
        "cn=$session->{data}->{_session_id}," . $self->{args}->{ldapConfBase} );
}

sub ldap {
    my $self = shift;
    return $self->{ldap} if ( $self->{ldap} );

    # Parse servers configuration
    my $useTls = 0;
    my $tlsParam;
    my @servers = ();
    foreach my $server ( split /[\s,]+/, $self->{args}->{ldapServer} ) {
        if ( $server =~ m{^ldap\+tls://([^/]+)/?\??(.*)$} ) {
            $useTls   = 1;
            $server   = $1;
            $tlsParam = $2 || "";
        }
        else {
            $useTls = 0;
        }
        push @servers, $server;
    }

    # Connect
    my $ldap = Net::LDAP->new(
        \@servers,
        onerror => undef,
        (
            $self->{args}->{ldapPort}
            ? ( port => $self->{args}->{ldapPort} )
            : ()
        ),
    ) or die( 'Unable to connect to ' . join( ' ', @servers ) );

    # Start TLS if needed
    if ($useTls) {
        my %h = split( /[&=]/, $tlsParam );
        $h{cafile} = $self->{args}->{caFile} if ( $self->{args}->{caFile} );
        $h{capath} = $self->{args}->{caPath} if ( $self->{args}->{caPath} );
        my $start_tls = $ldap->start_tls(%h);
        if ( $start_tls->code ) {
            $self->logError($start_tls);
            return;
        }
    }

    # Bind with credentials
    my $bind = $ldap->bind( $self->{args}->{ldapBindDN},
        password => $self->{args}->{ldapBindPassword} );
    if ( $bind->code ) {
        $self->logError($bind);
        return;
    }

    $self->{ldap} = $ldap;
    return $ldap;
}

sub logError {
    my $self           = shift;
    my $ldap_operation = shift;
    die "LDAP error " . $ldap_operation->code . ": " . $ldap_operation->error;
}

1;

=pod

=head1 NAME

Apache::Session::Browseable::Store::LDAP - Use LDAP to store persistent objects

=head1 SYNOPSIS

 use Apache::Session::Browseable::Store::LDAP;

 my $store = new Apache::Session::Browseable::Store::LDAP;

 $store->insert($ref);
 $store->update($ref);
 $store->materialize($ref);
 $store->remove($ref);

=head1 DESCRIPTION

This module fulfills the storage interface of Apache::Session.  The serialized
objects are stored in an LDAP directory file using the Net::LDAP Perl module.

=head1 OPTIONS

This module requires one argument in the usual Apache::Session style. The
keys ldapServer, ldapBase, ldapBindDN, ldapBindPassword are required. The key
ldapPort is optional. Example:

 tie %s, 'Apache::Session::Browseable::LDAP', undef,
    {
        ldapServer       => 'localhost',
        ldapBase         => 'dc=example,dc=com',
        ldapBindDN       => 'cn=admin,dc=example,dc=com',
        ldapBindPassword => 'pass',
        Index            => 'uid ipAddr',
    };

=head1 AUTHOR

Xavier Guimard, E<lt>guimard@E<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Xavier Guimard

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.0 or,
at your option, any later version of Perl 5 you may have available.

=head1 SEE ALSO

L<Apache::Session>

=cut
