package Apache::Session::Browseable::Redis;

use strict;

use Apache::Session;
use Apache::Session::Browseable::Store::Redis;
use Apache::Session::Generate::MD5;
use Apache::Session::Lock::Null;
use Apache::Session::Serialize::Base64;

our $VERSION = '0.2';
our @ISA     = qw(Apache::Session);

sub populate {
    my $self = shift;

    $self->{object_store} = new Apache::Session::Browseable::Store::Redis $self;
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

    my %res = ();
    my $index =
      ref( $args->{Index} ) ? $args->{Index} : [ split /\s+/, $args->{Index} ];
    if ( grep { $_ eq $selectField } @$index ) {
        my $redisObj = Redis->new(%$args);
        my @keys     = $redisObj->smembers("${selectField}_$value");
        foreach my $k (@keys) {
            next unless ($k);
            my $tmp = $redisObj->get($k);
            next unless ($tmp);
            $tmp = unserialize($tmp);
            if (@fields) {
                $res{$k}->{$_} = $tmp->{$_} foreach (@fields);
            }
            else {
                $res{$k} = $tmp;
            }
        }
    }
    else {
        $class->get_key_from_all_sessions(
            $args,
            sub {
                my $entry = shift;
                my $id    = shift;
                return undef unless ( $entry->{$selectField} eq $value );
                if (@fields) {
                    $res{$id}->{$_} = $entry->{$_} foreach (@fields);
                }
                else {
                    $res{$id} = $entry;
                }
                undef;
            }
        );
    }
    return \%res;
}

sub get_key_from_all_sessions {
    my $class = shift;
    my $args  = shift;
    my $data  = shift;
    my %res;

    # TODO new Redis object
    my $redisObj = Redis->new(%$args);
    my @keys     = $redisObj->keys('*');
    foreach my $k (@keys) {
        next if ( !$k or $k =~ /_/ );
        my $v   = $redisObj->get($k);
        my $tmp = unserialize($v);
        if ( ref($data) eq 'CODE' ) {
            $tmp = &$data( $tmp, $k );
            $res{$k} = $tmp if ( defined($tmp) );
        }
        elsif ($data) {
            $data = [$data] unless ( ref($data) );
            $res{$k}->{$_} = $tmp->{$_} foreach (@$data);
        }
        else {
            $res{$k} = $tmp;
        }
    }
    return \%res;
}

1;
__END__

=head1 NAME

Apache::Session::Browseable::Redis - Add index and search methods to
Apache::Session::Redis

=head1 SYNOPSIS

  use Apache::Session::Browseable::Redis;

  my $args = {
       server => '127.0.0.1:6379',

       # Choose your browseable fileds
       Index          => 'uid mail',
  };
  
  # Use it like Apache::Session
  my %session;
  tie %session, 'Apache::Session::Browseable::Redis', $id, $args;
  $session{uid} = 'me';
  $session{mail} = 'me@me.com';
  $session{unindexedField} = 'zz';
  untie %session;
  
  # Apache::Session::Browseable add some global class methods
  #
  # 1) search on a field (indexed or not)
  my $hash = Apache::Session::Browseable::Redis->searchOn( $args, 'uid', 'me' );
  foreach my $id (keys %$hash) {
    print $id . ":" . $hash->{$id}->{mail} . "\n";
  }

  # 2) Parse all sessions
  # a. get all sessions
  my $hash = Apache::Session::Browseable::Redis->get_key_from_all_sessions();

  # b. get some fields from all sessions
  my $hash = Apache::Session::Browseable::Redis->get_key_from_all_sessions('uid', 'mail')

  # c. execute something with datas from each session :
  #    Example : get uid and mail if mail domain is
  my $hash = Apache::Session::Browseable::Redis->get_key_from_all_sessions(
              sub {
                 my ( $session, $id ) = @_;
                 if ( $session->{mail} =~ /mydomain.com$/ ) {
                     return { $session->{uid}, $session->{mail} };
                 }
              }
  );
  foreach my $id (keys %$hash) {
    print $id . ":" . $hash->{$id}->{uid} . "=>" . $hash->{$id}->{mail} . "\n";
  }

=head1 DESCRIPTION

Apache::Session::browseable provides some class methods to manipulate all
sessions and add the capability to index some fields to make research faster.

=head1 SEE ALSO

L<Apache::Session>

=head1 AUTHOR

Xavier Guimard, E<lt>x.guimard@free.frE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2009 by Xavier Guimard

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.1 or,
at your option, any later version of Perl 5 you may have available.

=cut
