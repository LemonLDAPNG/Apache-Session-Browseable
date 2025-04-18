package Apache::Session::Browseable::Store::LDAP;

use strict;
use Net::LDAP;

our $VERSION = '1.3.8';

sub new {
    my $class = shift;
    return bless {}, $class;
}

sub insert {
    my $self    = shift;
    my $session = shift;
    $self->{args} = $session->{args};
    $self->{args}->{ldapObjectClass}      ||= 'applicationProcess';
    $self->{args}->{ldapAttributeId}      ||= 'cn';
    $self->{args}->{ldapAttributeContent} ||= 'description';
    $self->{args}->{ldapAttributeIndex}   ||= 'ou';

    my $index =
      ref( $session->{args}->{Index} )
      ? $session->{args}->{Index}
      : [ split /\s+/, $session->{args}->{Index} ];
    my $id = $session->{data}->{_session_id};

    my $attrIndex;
    foreach my $i (@$index) {
        my $t;
        next unless ( $t = $session->{data}->{$i} );
        push @$attrIndex, "${i}_$t";
    }
    my $attrs = [
        objectClass                      => $self->{args}->{ldapObjectClass},
        $self->{args}->{ldapAttributeId} => $session->{data}->{_session_id},
        $self->{args}->{ldapAttributeContent} => $session->{serialized},
    ];
    push @$attrs, ( $self->{args}->{ldapAttributeIndex} => $attrIndex )
      if ($attrIndex);

    my $msg = $self->ldap->add(
        $self->{args}->{ldapAttributeId} . "=$id,"
          . $self->{args}->{ldapConfBase},
        attrs => $attrs,
    );

    $self->ldap->unbind() && delete $self->{ldap};
    $self->logError($msg) if ( $msg->code );
}

sub update {
    my $self    = shift;
    my $session = shift;
    $self->{args} = $session->{args};
    $self->{args}->{ldapObjectClass}      ||= 'applicationProcess';
    $self->{args}->{ldapAttributeId}      ||= 'cn';
    $self->{args}->{ldapAttributeContent} ||= 'description';
    $self->{args}->{ldapAttributeIndex}   ||= 'ou';

    my $index =
      ref( $session->{args}->{Index} )
      ? $session->{args}->{Index}
      : [ split /\s+/, $session->{args}->{Index} ];
    my $id = $session->{data}->{_session_id};

    my $attrIndex;
    foreach my $i (@$index) {
        my $t;
        next unless ( $t = $session->{data}->{$i} );
        push @$attrIndex, "${i}_$t";
    }

    my $attrs =
      { $self->{args}->{ldapAttributeContent} => $session->{serialized} };
    $attrs->{ $self->{args}->{ldapAttributeIndex} } = $attrIndex
      if ($attrIndex);

    my $msg = $self->ldap->modify(
        $self->{args}->{ldapAttributeId} . "="
          . $session->{data}->{_session_id} . ","
          . $self->{args}->{ldapConfBase},
        replace => $attrs,
    );

    $self->ldap->unbind() && delete $self->{ldap};
    $self->logError($msg) if ( $msg->code );
}

sub materialize {
    my $self    = shift;
    my $session = shift;
    $self->{args} = $session->{args};
    $self->{args}->{ldapObjectClass}      ||= 'applicationProcess';
    $self->{args}->{ldapAttributeId}      ||= 'cn';
    $self->{args}->{ldapAttributeContent} ||= 'description';
    $self->{args}->{ldapAttributeIndex}   ||= 'ou';

    my $msg = $self->ldap->search(
        base => $self->{args}->{ldapAttributeId} . "="
          . $session->{data}->{_session_id} . ","
          . $self->{args}->{ldapConfBase},
        filter => '(objectClass=' . $self->{args}->{ldapObjectClass} . ')',
        scope  => 'base',
        attrs  => [ $self->{args}->{ldapAttributeContent} ],
    );

    $self->ldap->unbind() && delete $self->{ldap};
    $self->logError($msg) if ( $msg->code );

    eval {
        $session->{serialized} = $msg->shift_entry()
          ->get_value( $self->{args}->{ldapAttributeContent} );
    };

    if ( !defined $session->{serialized} ) {
        die "Object does not exist in data store";
    }
}

sub remove {
    my $self    = shift;
    my $session = shift;
    $self->{args} = $session->{args};
    $self->{args}->{ldapObjectClass}      ||= 'applicationProcess';
    $self->{args}->{ldapAttributeId}      ||= 'cn';
    $self->{args}->{ldapAttributeContent} ||= 'description';
    $self->{args}->{ldapAttributeIndex}   ||= 'ou';

    $self->ldap->delete( $self->{args}->{ldapAttributeId} . "="
          . $session->{data}->{_session_id} . ","
          . $self->{args}->{ldapConfBase} );

    $self->ldap->unbind() && delete $self->{ldap};
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

    # Compatibility
    my $caFile = $self->{args}->{ldapCAFile} || $self->{args}->{caFile};
    my $caPath = $self->{args}->{ldapCAPath} || $self->{args}->{caPath};

    # Connect
    my $ldap = Net::LDAP->new(
        \@servers,
        onerror => undef,
        verify  => $self->{args}->{ldapVerify} || "require",
        ( $caFile ? ( cafile => $caFile ) : () ),
        ( $caPath ? ( capath => $caPath ) : () ),

        (
            $self->{args}->{ldapRaw} ? ( raw => $self->{args}->{ldapRaw} )
            : ()
        ),
        (
            $self->{args}->{ldapPort} ? ( port => $self->{args}->{ldapPort} )
            : ()
        ),
    ) or die( 'Unable to connect to ' . join( ' ', @servers ) . ": " . $@ );

    # Check SSL error for old Net::LDAP versions
    if ( $Net::LDAP::VERSION < '0.64' ) {

        # CentOS7 has a bug in which IO::Socket::SSL will return a broken
        # socket when certificate validation fails. Net::LDAP does not catch
        # it, and the process ends up crashing.
        # As a precaution, make sure the underlying socket is doing fine:
        if (    $ldap->socket->isa('IO::Socket::SSL')
            and $ldap->socket->errstr < 0 )
        {
            die( "SSL connection error: " . $ldap->socket->errstr );
        }
    }

    # Start TLS if needed
    if ($useTls) {
        my %h = split( /[&=]/, $tlsParam );
        $h{verify} ||= ( $self->{args}->{ldapVerify} || "require" );
        $h{cafile} ||= $caFile if ($caFile);
        $h{capath} ||= $caPath if ($caPath);
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
ldapPort, ldapObjectClass, ldapAttributeId, ldapAttributeContent,
ldapAttributeIndex, and ldapRaw are optional.
Example:

 tie %s, 'Apache::Session::Browseable::LDAP', undef,
    {
        ldapServer           => 'localhost',
        ldapBase             => 'dc=example,dc=com',
        ldapBindDN           => 'cn=admin,dc=example,dc=com',
        ldapBindPassword     => 'pass',
        Index                => 'uid ipAddr',
        ldapObjectClass      => 'applicationProcess',
        ldapAttributeId      => 'cn',
        ldapAttributeContent => 'description',
        ldapAttributeIndex   => 'ou',
        ldapRaw              => '(?i:^jpegPhoto|;binary)',
    };

=head1 COPYRIGHT AND LICENSE

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
