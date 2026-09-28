package Apache::Session::Browseable::Store::LDAP;

use strict;
use Net::LDAP;

our $VERSION = '1.3.9';

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
    return $self->{ldap} if $self->{ldap};

    # Parse servers configuration
    my ( @servers, %tlsParams, $useStartTls );

    foreach my $server ( split /[\s,]+/, $self->{args}->{ldapServer} ) {
        if ( $server =~ m{^ldap\+tls://([^/]+)/?\??(.*)$} ) {
            $useStartTls = 1;
            $server      = $1;
            %tlsParams   = split( /[&=]/, $2 || "" );
        }
        elsif ( $server =~ m{^(ldaps://[^/]+)/?\??(.*)$} ) {
            $useStartTls = 0;
            $server      = $1;
            %tlsParams   = split( /[&=]/, $2 || "" );
        }
        else {
            $useStartTls = 0;
        }
        push @servers, $server;
    }

    # Compatibility
    $tlsParams{cafile} ||=
      $self->{args}->{ldapCAFile} || $self->{args}->{caFile};
    $tlsParams{capath} ||=
      $self->{args}->{ldapCAPath} || $self->{args}->{caPath};
    $tlsParams{verify} ||= $self->{args}->{ldapVerify} || "require";
    eval { require Authen::SASL if $self->{args}->{ldapClientCert}; };
    if ($@) {
        die( 'Authen::SASL is required to connect using mTLS: ' . $@ );
    }
    else {
        $tlsParams{clientcert} ||= $self->{args}->{ldapClientCert}
          if $self->{args}->{ldapClientCert};
        $tlsParams{clientkey} ||= $self->{args}->{ldapClientKey}
          if $self->{args}->{ldapClientKey};
    }

    # Connect
    my $ldap = Net::LDAP->new(
        \@servers,
        onerror   => undef,
        keepalive => 1,
        %tlsParams,
        (
            $self->{args}->{ldapRaw} ? ( raw => $self->{args}->{ldapRaw} )
            : ()
        ),
        (
            $self->{args}->{ldapPort} ? ( port => $self->{args}->{ldapPort} )
            : ()
        ),
        (
            $self->{args}->{ldapTimeout}
            ? ( timeout => $self->{args}->{ldapTimeout} )
            : ()
        )
    );

    unless ($ldap) {
        die( 'Unable to connect to ' . join( ' ', @servers ) . ": " . $@ );
    }
    elsif ( $Net::LDAP::VERSION < '0.64' ) {

        # CentOS7 has a bug in which IO::Socket::SSL will return a broken
        # socket when certificate validation fails. Net::LDAP does not catch
        # it, and the process ends up crashing.
        # As a precaution, make sure the underlying socket is doing fine:
        if (    $ldap->socket->isa('IO::Socket::SSL')
            and $ldap->socket->errstr )
        {
            die "SSL connection error: " . $ldap->socket->errstr;
        }
    }

    # Start TLS if needed
    my $socket = $ldap->socket;
    IO::Socket::Timeout->enable_timeouts_on($socket);
    $socket->read_timeout( $self->{args}->{ldapIOTimeout} );
    $socket->write_timeout( $self->{args}->{ldapIOTimeout} );

    if ($useStartTls) {
        my $mesg = $ldap->start_tls(%tlsParams);
        $self->logError($mesg) if $mesg->code;
    }

    # Bind with credentials
    my $bind = $self->_bind( $ldap, $tlsParams{clientcert} );
    $self->logError($bind) if $bind->code; 

    $self->{ldap} = $ldap;
    return $ldap;
}

sub _bind {
    my ( $self, $ldap, $sasl ) = @_;

    if ( $self->{args}->{ldapBindDN} && $self->{args}->{ldapBindPassword} ) {
        return $ldap->bind( $self->{args}->{ldapBindDN},
            password => $self->{args}->{ldapBindPassword} );
    }
    elsif ($self->{args}->{ldapClientCert}
        && $self->{args}->{ldapClientKey}
        && $sasl )
    {
        my $sasl = Authen::SASL->new(
            mechanism => 'EXTERNAL',
            callback  => { user => '' }
        );
        return $ldap->bind( undef, sasl => $sasl );
    }
    else {
        return $ldap->bind();
    }
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
