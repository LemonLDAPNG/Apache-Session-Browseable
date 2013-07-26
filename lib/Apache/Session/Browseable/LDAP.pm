package Apache::Session::Browseable::LDAP;

use strict;

use Apache::Session;
use Apache::Session::Lock::Null;
use Apache::Session::Browseable::Store::LDAP;
use Apache::Session::Generate::MD5;
use Apache::Session::Serialize::Base64;
use Apache::Session::Browseable::_common;
use Net::LDAP::Util qw(escape_filter_value);

our $VERSION = '1.0';
our @ISA     = qw(Apache::Session Apache::Session::Browseable::_common);

sub populate {
    my $self = shift;

    $self->{object_store} = new Apache::Session::Browseable::Store::LDAP $self;
    $self->{lock_manager} = new Apache::Session::Lock::Null $self;
    $self->{generate}     = \&Apache::Session::Generate::MD5::generate;
    $self->{validate}     = \&Apache::Session::Generate::MD5::validate;
    $self->{serialize}    = \&Apache::Session::Serialize::Base64::serialize;
    $self->{unserialize}  = \&Apache::Session::Serialize::Base64::unserialize;

    return $self;
}

sub unserialize {
    my $session = shift;
    my $tmp = { serialized => $session };
    Apache::Session::Serialize::Base64::unserialize($tmp);
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

sub _query {
    my ( $class, $args, $selectField, $value, @fields ) = @_;

    my %res = ();
    my $ldap =
      Apache::Session::Browseable::Store::LDAP::ldap( { args => $args } );
    my $msg = $ldap->search(
        base => $args->{ldapConfBase},
        filter =>
          "(&(objectClass=applicationProcess)(ou=${selectField}_$value))",

        #scope => 'base',
        attrs => [ 'description', 'cn' ],
    );
    if ( $msg->code ) {
        Apache::Session::Browseable::Store::LDAP->logError($msg);
    }
    else {
        foreach my $entry ( $msg->entries ) {
            my $id = $entry->get_value('cn') or die;
            my $tmp = $entry->get_value('description');
            next unless ($tmp);
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
    my %res;

    my $ldap =
      Apache::Session::Browseable::Store::LDAP::ldap( { args => $args } );
    my $msg = $ldap->search(
        base => $args->{ldapConfBase},

     # VERY STRANGE BUG ! With this filter, description isn't base64 encoded !!!
     #filter => '(objectClass=applicationProcess)',
        filter => '(&(objectClass=applicationProcess)(ou=*))',
        attrs  => [ 'cn', 'description' ],
    );
    if ( $msg->code ) {
        Apache::Session::Browseable::Store::LDAP->logError($msg);
    }
    else {
        foreach my $entry ( $msg->entries ) {
            my $id = $entry->get_value('cn') or die;
            my $tmp = $entry->get_value('description');
            next unless ($tmp);
            eval { $tmp = unserialize($tmp); };
            next if ($@);
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

1;

=pod

=head1 NAME

Apache::Session::Browseable::LDAP - An implementation of Apache::Session::LDAP

=head1 SYNOPSIS

  use Apache::Session::Browseable::LDAP;
  tie %hash, 'Apache::Session::Browseable::LDAP', $id, {
    ldapServer       => 'ldap://localhost:389',
    ldapConfBase     => 'dmdName=applications,dc=example,dc=com',
    ldapBindDN       => 'cn=admin,dc=example,dc=com',
    ldapBindPassword => 'pass',
    Index            => 'uid ipAddr',
  };

=head1 DESCRIPTION

This module is an implementation of Apache::Session. It uses an LDAP directory
to store datas.

=head1 AUTHOR

Xavier Guimard, E<lt>x.guimard@free.frE<gt>

=head1 COPYRIGHT AND LICENSE

=encoding utf8

Copyright (C) 2009 by Xavier Guimard
              2013 by Clément Oudot

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.0 or,
at your option, any later version of Perl 5 you may have available.

=head1 SEE ALSO

L<Apache::Session>

=cut
