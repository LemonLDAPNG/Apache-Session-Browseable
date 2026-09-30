package Apache::Session::Browseable::Redis;

use strict;

use Apache::Session;
use Apache::Session::Browseable::Store::Redis;
use Apache::Session::Generate::SHA256;
use Apache::Session::Lock::Null;
use Apache::Session::Serialize::JSON;
use Apache::Session::Browseable::_common;

our $VERSION = '1.3.18';
our @ISA     = qw(Apache::Session);

sub populate {
    my $self = shift;

    $self->{object_store} = new Apache::Session::Browseable::Store::Redis $self;
    $self->{lock_manager} = new Apache::Session::Lock::Null $self;
    $self->{generate}     = \&Apache::Session::Generate::SHA256::generate;
    $self->{validate}     = \&Apache::Session::Generate::SHA256::validate;
    $self->{serialize}    = \&Apache::Session::Serialize::JSON::serialize;
    $self->{unserialize} =
      \&Apache::Session::Serialize::JSON::unserializeLatin1;

    return $self;
}

sub unserialize {
    my $session = shift;
    my $tmp     = { serialized => $session };
    Apache::Session::Serialize::JSON::unserializeLatin1($tmp);
    return $tmp->{data};
}

# Remove session KEYS[2] from index KEYS[1] only if it doesn't exist, in one
# step: a concurrent writer may be recreating it
our $SREM_ORPHAN = q{if redis.call('exists',KEYS[2])==0 then }
  . q{return redis.call('srem',KEYS[1],KEYS[2]) end return 0};

# Sessions of index set $set, except those in %$skip: { id => session }.
# Members that may belong to another app are neither read nor removed
sub _readIndex {
    my ( $class, $args, $redisObj, $set, $skip ) = @_;
    my @keys = eval { $redisObj->smembers($set) };

    # Like the MGET below: a transient error (MOVED, LOADING, timeout...)
    # must not break the whole search, and must not lose any data
    if ($@) {
        return {} if ( $@ =~ /WRONGTYPE/ );
        print STDERR "Error when reading index $set: $@\n";
        return {};
    }
    @keys = grep {
              $_
          and !( $skip and exists $skip->{$_} )
          and $class->isLlngKey( $args, $_ )
    } @keys;
    return {} unless (@keys);

    # MGET returns undef for missing keys and keys that aren't strings
    my @values = eval { $redisObj->mget(@keys) };
    if ($@) {
        print STDERR "Error when reading index $set: $@\n";
        return {};
    }
    my %res;
    foreach my $i ( 0 .. $#keys ) {
        my ( $k, $tmp ) = ( $keys[$i], $values[$i] );
        unless ($tmp) {

            # Lazy cleanup: remove orphan from index
            eval { $redisObj->eval( $SREM_ORPHAN, 2, $set, $k ) };
            next;
        }
        $tmp = eval { unserialize($tmp) };
        if ( $@ or ref($tmp) ne 'HASH' ) {
            print STDERR "Error in session $k: " . ( $@ || "not a session\n" );
            next;
        }
        $res{$k} = $tmp;
    }
    return \%res;
}

# searchOnExpr() patterns: '*' is a wildcard
sub _exprRe {
    my ($value) = @_;
    $value = quotemeta($value);
    $value =~ s/\\\*/\.\*/g;
    return qr/^$value$/;
}

# Add decoded sessions whose $selectField matches $test to $res: the index
# may be stale (concurrent rewrite, missed SREM)
sub _keepMatching {
    my ( $class, $res, $sessions, $selectField, $test, @fields ) = @_;
    foreach my $id ( keys %$sessions ) {
        my $v = $sessions->{$id}->{$selectField};
        next unless ( defined $v and $test->($v) );
        $res->{$id} = $class->extractFields( $sessions->{$id}, @fields );
    }
}

sub searchOn {
    my ( $class, $args, $selectField, $value, @fields ) = @_;

    my %res = ();
    if ( $class->isIndexed( $args, $selectField ) ) {

        my $redisObj = $class->_getRedis($args);
        my $sessions =
          $class->_readIndex( $args, $redisObj, "${selectField}_$value" );
        $class->_keepMatching( \%res, $sessions, $selectField,
            sub { $_[0] eq $value }, @fields );
    }
    else {
        $class->get_key_from_all_sessions(
            $args,
            sub {
                my $entry = shift;
                my $id    = shift;
                return undef
                  unless ( defined $entry->{$selectField}
                    and $entry->{$selectField} eq $value );
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

sub searchOnExpr {
    my ( $class, $args, $selectField, $value, @fields ) = @_;
    my %res;
    my $re = _exprRe($value);
    if ( $class->isIndexed( $args, $selectField ) ) {
        my $redisObj = $class->_getRedis($args);
        my $cursor   = 0;
        do {
            my ( $new_cursor, $sets ) =
              $redisObj->scan( $cursor, MATCH => "${selectField}_$value" );
            foreach my $set (@$sets) {
                my $sessions =
                  $class->_readIndex( $args, $redisObj, $set, \%res );
                $class->_keepMatching( \%res, $sessions, $selectField,
                    sub { $_[0] =~ $re }, @fields );
            }
            $cursor = $new_cursor;
        } while ( $cursor != 0 );
    }
    else {
        $class->get_key_from_all_sessions(
            $args,
            sub {
                my ( $entry, $id ) = @_;
                return undef unless ( $entry->{$selectField} =~ $re );
                $res{$id} = $class->extractFields( $entry, @fields );
                undef;
            }
        );
    }
    return \%res;
}

sub searchLt {
    my $class = shift;
    return $class->_searchCompare( '<', @_ );
}

sub searchGt {
    my $class = shift;
    return $class->_searchCompare( '>', @_ );
}

# Trimmed number, or undef
sub _number {
    my ($v) = @_;
    return undef unless ( defined($v) and !ref($v) );
    $v =~ s/^\s+|\s+$//g;
    return $v =~ /^-?[0-9]+(?:\.[0-9]+)?\z/ ? $v : undef;
}

# Sessions where $selectField isn't a number (see _number()) are skipped.
# Indexed field: SCAN walks the keyspace server-side and returns only the
# index sets of $selectField; only sets holding a matching value are read
sub _searchCompare {
    my ( $class, $op, $args, $selectField, $value, @fields ) = @_;

    # LLNG CLI keeps spaces around the value ("--where 'f < 123 '")
    $value = _number($value);
    unless ( defined $value ) {
        print STDERR 'search'
          . ( $op eq '<' ? 'Lt' : 'Gt' )
          . ": value must be a number\n";
        return {};
    }
    my $test = sub {
        my $v = _number(shift);
        return 0 unless ( defined $v );
        return $op eq '<' ? $v < $value : $v > $value;
    };
    my %res;
    unless ( $class->isIndexed( $args, $selectField ) ) {
        $class->get_key_from_all_sessions(
            $args,
            sub {
                my ( $entry, $id ) = @_;
                $res{$id} = $class->extractFields( $entry, @fields )
                  if ( $test->( $entry->{$selectField} ) );
                undef;
            }
        );
        return \%res;
    }

    my $redisObj = $class->_getRedis($args);
    my $prefix   = "${selectField}_";
    ( my $pattern = $prefix ) =~ s/([*?\[\]\\])/\\$1/g;
    my $cursor = 0;
    do {
        my ( $new_cursor, $sets ) =
          $redisObj->scan( $cursor, MATCH => "$pattern*", COUNT => 1000 );
        foreach my $set (@$sets) {

            # Sets of other fields ("${selectField}_x_1") aren't numbers
            next unless ( $test->( substr( $set, length($prefix) ) ) );
            my $sessions = $class->_readIndex( $args, $redisObj, $set, \%res );

            # The index may be stale: check the session itself
            $class->_keepMatching( \%res, $sessions, $selectField, $test,
                @fields );
        }
        $cursor = $new_cursor;
    } while ( $cursor != 0 );
    return \%res;
}

sub deleteIfLowerThan {
    my ( $class, $args, $rule ) = @_;
    my $deleted  = 0;
    my $redisObj = $class->_getRedis($args);
    my $index =
      ref( $args->{Index} )
      ? $args->{Index}
      : [ split /\s+/, $args->{Index} ];

    $class->get_key_from_all_sessions(
        $args,
        sub {
            my ( $v, $k ) = @_;
            if ( $rule->{not} ) {
                foreach ( keys %{ $rule->{not} } ) {
                    if (defined( $v->{$_} ) and $v->{$_} eq $rule->{not}->{$_}) {
                        return ();
                    }
                }
            }
            # Empty or data-less sessions should be purged
            my $dominated = 0;
            if ( !$v || !%$v || !exists $v->{_session_id} ) {
                $dominated = 1;
            }
            elsif ( $rule->{or} ) {
                foreach ( keys %{ $rule->{or} } ) {
                    if ( !defined( $v->{$_} ) ) {
                        # Session missing a required field: treat as expired
                        $dominated = 1;
                        last;
                    }
                    if ( $v->{$_} < $rule->{or}->{$_} ) {
                        $dominated = 1;
                        last;
                    }
                }
            }
            elsif ( $rule->{and} ) {
                my $res = 1;
                foreach ( keys %{ $rule->{and} } ) {
                    $res = 0
                      unless !defined( $v->{$_} )
                      or $v->{$_} < $rule->{and}->{$_};
                }
                $dominated = $res;
            }
            if ($dominated) {
                # Clean up index entries before deleting the session
                my $index_ok = 1;
                foreach my $i (@$index) {
                    my $t = $v->{$i};
                    next unless ( defined($t) and length($t) > 0 );
                    eval { $redisObj->srem( "${i}_$t", $k ) };
                    if ($@) {
                        warn "Failed to remove '$k' from index '${i}_$t': $@";
                        $index_ok = 0;
                    }
                }
                if ($index_ok) {
                    $redisObj->del($k);
                    $deleted++;
                }
                else {
                    warn "Skipping deletion of session '$k' due to index cleanup failure";
                }
            }
            return ();
        },
    );
    return ( 1, $deleted );
}

sub extractFields {
    my ( $class, $entry, @fields ) = @_;
    my $res;
    if (@fields) {
        $res->{$_} = $entry->{$_} foreach (@fields);
    }
    else {
        $res = $entry;
    }
    return $res;
}

sub isIndexed {
    my ( $class, $args, $field ) = @_;
    my $indexes =
      ref( $args->{Index} ) ? $args->{Index} : [ split /\s+/, $args->{Index} ];
    return grep { $_ eq $field } @$indexes;
}

my %keysRe_re;
sub isLlngKey {
    my ( $class, $args, $name ) = @_;
    my $expr = $args->{keysRe} || '^[0-9a-f]{32,}$';

    # Compile per expression: a process may use several keysRe
    $keysRe_re{$expr} = qr/$expr/ unless ( exists $keysRe_re{$expr} );
    return ( $name =~ $keysRe_re{$expr} );
}

sub get_key_from_all_sessions {
    my ( $class, $args, $data ) = @_;
    my %res;

    my $redisObj = $class->_getRedis($args);
    my $cursor   = 0;
    do {
        my ( $new_cursor, $keys ) = $redisObj->scan($cursor);
        foreach my $k (@$keys) {

            # Keep only our keys
            next unless $class->isLlngKey( $args, $k );

            # Don't scan sets,...
            next unless $redisObj->type($k) eq 'string';
            eval {
                my $v = $redisObj->get($k);
                next unless $v;
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
            };
            if ($@) {
                print STDERR "Error in session $k: $@\n";

                # Don't delete, it may own to another app
                #delete $res{$k};
            }
        }
        $cursor = $new_cursor;
    } while ( $cursor != 0 );
    return \%res;
}

sub _getRedis {
    my ( $class, $args ) = @_;
    return Apache::Session::Browseable::Store::Redis->_getRedis($args);
}

1;
__END__

=encoding utf8

=head1 NAME

Apache::Session::Browseable::Redis - Add index and search methods to
Apache::Session::Redis

=head1 SYNOPSIS

  use Apache::Session::Browseable::Redis;

  my $args = {
       server => '127.0.0.1:6379',

       # Select database (optional)
       #database => 0,

       # Use a persistent connection to the Redis server
       # (value is the connection cache key)
       # You'll probably also want to set
       # read_timeout, write_timeout, reconnect and every
       reuse => "myserver",

       # Choose your browseable fields
       Index          => 'uid mail',

       # Optional: set a Redis TTL on session keys (in seconds)
       # TTL => 86400,
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
  my $hash = Apache::Session::Browseable::Redis->get_key_from_all_sessions($args);

  # b. get some fields from all sessions
  my $hash = Apache::Session::Browseable::Redis->get_key_from_all_sessions($args, 'uid', 'mail')

  # c. execute something with datas from each session :
  #    Example : get uid and mail if mail domain is
  my $hash = Apache::Session::Browseable::Redis->get_key_from_all_sessions(
              $args,
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

This module use either L<Redis::Fast> or L<Redis>.

=head1 searchLt() AND searchGt()

  # Sessions where _oidcRtUpdate < $time (or > $time)
  my $hash = Apache::Session::Browseable::Redis->searchLt(
      $args, '_oidcRtUpdate', $time );
  $hash = Apache::Session::Browseable::Redis->searchGt(
      $args, '_oidcRtUpdate', $time, 'uid', 'client_id' );

They return sessions whose field is strictly lower (or greater) than the
given value, like L<searchOn()|/SYNOPSIS>: C<{ id =E<gt> session }>, or only
the requested fields. The comparison is numeric.

Leading and trailing spaces of the value are removed, then it must match
C</^-?[0-9]+(?:\.[0-9]+)?\z/>. Otherwise, an error is
printed on STDERR and an empty hash is returned.

Sessions where the field is missing, empty or not a number (same check as the
value, so C<Inf> or C<1e3> are skipped) are never returned. This differs from
the SQL backends, which compare a non-numeric value as 0 (and cast its numeric
prefix: C<250x> is 250), so C<searchLt($args, 'f', 10)> returns a session
where C<f> is C<abc> with them, but not with Redis. Numbers must be written
in plain decimal form to be found. Likewise, the Perl fallback of
Lemonldap::NG, used with backends that don't provide these methods, compares
a missing field as 0.

If the field isn't listed in C<Index>, all sessions are read and decoded. If
it is, Redis still walks the whole keyspace (C<SCAN ... MATCH field_*>), but
server-side: only the index sets of this field (C<field_value> keys) are
returned, and only the sessions of sets holding a matching value are read.
Orphan entries of these sets are removed; keys that don't match C<keysRe>
are ignored.

For the Lemonldap::NG purge of OpenID Connect refresh tokens, add
C<_oidcRtUpdate> to C<Index>. Sessions stored before a field is added to
C<Index> are not in its index until they are saved again, and refresh tokens
are saved only when used: inactive ones won't be found by C<searchLt()> and
will only be purged when C<_utime> expires. To index them at once, re-save
them:

  my $rt = Apache::Session::Browseable::Redis->get_key_from_all_sessions(
      $args, sub { $_[0]->{_oidcRtUpdate} } );
  foreach my $id ( keys %$rt ) {
      tie my %s, 'Apache::Session::Browseable::Redis', $id, $args;
      $s{_oidcRtUpdate} = $s{_oidcRtUpdate};
      untie %s;
  }

This also refreshes their C<TTL>, if any.

=head1 SEE ALSO

L<Apache::Session>

=head1 COPYRIGHT AND LICENSE

=over

=item 2009-2025 by Xavier Guimard

=item 2013-2025 by Clément Oudot

=item 2019-2025 by Maxime Besson

=item 2013-2025 by Worteks

=item 2023-2025-2025 by Linagora

=back

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.1 or,
at your option, any later version of Perl 5 you may have available.

=cut
