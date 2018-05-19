package Apache::Session::Browseable::Store::Redis;

use strict;

our $VERSION = '1.2.2';
our $redis;

BEGIN {
    $redis = 'Redis::Fast';
    eval 'use Redis::Fast';
    if ($@) {
        require Redis;
        $redis = 'Redis';
    }
}

sub new {
    my ( $class, $session ) = @_;
    my $self;

    # Manage undef encoding
    $session->{args}->{encoding} = undef
      if (  $session->{args}->{encoding}
        and $session->{args}->{encoding} eq "undef" );

    $self->{cache} = $redis->new( %{ $session->{args} } );

    # Manage database
    $self->{cache}->select( $session->{args}->{database} )
      if defined $session->{args}->{database};

    bless $self, $class;
}

sub insert {
    my ( $self, $session ) = @_;
    my $index =
      ref( $session->{args}->{Index} )
      ? $session->{args}->{Index}
      : [ split /\s+/, $session->{args}->{Index} ];

    my $id = $session->{data}->{_session_id};
    $self->{cache}->set( $id, $session->{serialized} );
    foreach my $i (@$index) {
        my $t;
        next unless ( $t = $session->{data}->{$i} );
        $self->{cache}->sadd( "${i}_$t", $id );
    }
}

*update = *insert;

sub materialize {
    my ( $self, $session ) = @_;
    $session->{serialized} =
      $self->{cache}->get( $session->{data}->{_session_id} )
      or die 'Object does not exist in data store.';
}

sub remove {
    my ( $self, $session ) = @_;
    my $index =
      ref( $session->{args}->{Index} )
      ? $session->{args}->{Index}
      : [ split /\s+/, $session->{args}->{Index} ];

    my $id = $session->{data}->{_session_id};
    foreach my $i (@$index) {
        my $t;
        next unless ( $t = $session->{data}->{$i} );
        eval { $self->{cache}->srem( "${i}_$t", $id ); };
    }
    $self->{cache}->del($id);
}

1;
__END__

=pod

=head1 NAME

Apache::Session::Browseable::Store::Redis - An implementation of
Apache::Session::Store

=head1 SYNOPSIS

 use Apache::Session::Browseable::Redis;
 
 tie %hash, 'Apache::Session::Browseable::Redis', $id, {
    # optional: default to localhost
    server => '127.0.0.1:6379',
 };

=head1 DESCRIPTION

This module is an implementation of Apache::Session::Browseable. It uses the
Redis storage system

=head1 SEE ALSO

L<Apache::Session::Browseable>, L<Apache::Session::NoSQL>, L<Apache::Session>

=head1 AUTHOR

This module was written by Xavier Guimard <x.guimard@free.fr>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2009-2018 by Xavier Guimard

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.1 or,
at your option, any later version of Perl 5 you may have available.

=cut
