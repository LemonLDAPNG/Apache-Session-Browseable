# Directly copied from Lemonldap::NG project (http://lemonldap-ng.org/)
package Apache::Session::Serialize::JSON;

use strict;
use JSON qw(to_json);

our $VERSION = '1.2.6';

my $json     = JSON->new->allow_nonref;
my $utf8Json = JSON->new->utf8->allow_nonref;

sub serialize {
    my $session = shift;

    $session->{serialized} = to_json( $session->{data}, { allow_nonref => 1 } );

    # JSON::PP doesn't flag its result as UTF-8 when data holds only Latin-1
    # characters: some DBD drivers would then store Latin-1 bytes
    utf8::upgrade( $session->{serialized} );
    return $session->{serialized};
}

sub unserialize {
    my ( $session, $next ) = @_;

    my $data = _unserialize( $session->{serialized}, $next );
    die "Session could not be unserialized" unless defined $data;
    $session->{data} = $data;
}

# For stores that never return UTF-8 bytes (Redis stores Latin-1)
sub unserializeLatin1 {
    my ( $session, $next ) = @_;

    my $data = _unserialize( $session->{serialized}, $next, 1 );
    die "Session could not be unserialized" unless defined $data;
    $session->{data} = $data;
}

sub _unserialize {
    my ( $serialized, $next, $latin1 ) = @_;
    my $tmp;

    # Some stores (MySQL json columns, files,...) return UTF-8 bytes
    if ( defined $serialized and !$latin1 and !utf8::is_utf8($serialized) ) {
        $tmp = eval { $utf8Json->decode($serialized) };
        return $tmp unless ($@);
    }
    eval { $tmp = $json->decode($serialized) };
    if ($@) {
        require Storable;
        $next ||= \&Storable::thaw;
        return &$next($serialized);
    }
    return $tmp;
}

1;

=pod

=head1 NAME

=encoding utf8

Apache::Session::Serialize::JSON - Use JSON to zip up data

=head1 SYNOPSIS

 use Apache::Session::Serialize::JSON;

 $zipped = Apache::Session::Serialize::JSON::serialize($ref);
 $ref = Apache::Session::Serialize::JSON::unserialize($zipped);

=head1 DESCRIPTION

This module fulfills the serialization interface of Apache::Session.
It serializes the data in the session object by use of JSON C<to_json>
and C<from_json>. The serialized data is UTF-8 text.

When reading, a string returned as bytes by the store (not flagged as UTF-8,
for example a MySQL C<json> column) is first decoded as UTF-8 JSON; if it is
not valid UTF-8, it is read as characters.

Some stores return Latin-1 bytes instead: files when the session holds only
Latin-1 characters, and Redis, which can't store other characters. A Latin-1
session that is also valid UTF-8 is then read as UTF-8: for example "Ã©"
becomes "é". This needs every non-ASCII character of the session to be part
of such a sequence (mostly values that are already mojibake). The Redis
backend avoids it with C<unserializeLatin1()>, which skips the UTF-8 decode.

=head1 UPGRADE

Previous versions read UTF-8 bytes returned by the store as Latin-1. The
serialized data is unchanged, so they still read sessions as they did
before. But a session rewritten by a previous version during a rolling
upgrade keeps the double-encoded values it read, and sessions already
corrupted this way are not repaired. Upgrade all servers sharing sessions
(for Lemonldap::NG, all portals and handlers) together.

=head1 SEE ALSO

L<JSON>, L<Apache::Session>

=head1 BUG REPORT

Use OW2 system to report bug or ask for features:
L<http://jira.ow2.org>

=head1 COPYRIGHT AND LICENSE

=over

=item 2009-2025 by Xavier Guimard

=item 2013-2025 by Clément Oudot

=item 2019-2025 by Maxime Besson

=item 2013-2025 by Worteks

=item 2023-2025 by Linagora

=back

This library is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2, or (at your option)
any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see L<http://www.gnu.org/licenses/>.

=cut
