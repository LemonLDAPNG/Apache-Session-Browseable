use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

# Non-ASCII values must survive a round trip through each backend
my $latin = "\x{c9}lodie";            # Latin-1 range
my $wide  = "\x{c9}lodie \x{3a9}";    # beyond Latin-1

sub roundTrip {
    my ( $label, $class, $args, @values ) = @_;
    foreach my $v (@values) {
        ( my $l = $v ) =~ s/[^ -~]/?/g;
        $l = "$label: $l";
        my %session;
        tie %session, $class, undef, $args;
        $session{uid}  = 'u8';
        $session{cn}   = $v;
        $session{list} = [$v];
        my $id = $session{_session_id};
        untie %session;

        tie %session, $class, $id, $args;
        is( $session{cn}, $v, "$l retrieved" );
        is_deeply( $session{list}, [$v], "$l in array retrieved" );
        untie %session;
        my $r = $class->get_key_from_all_sessions($args);
        is( $r->{$id}->{cn}, $v, "$l: get_key_from_all_sessions" );
        $r = $class->get_key_from_all_sessions( $args, sub { $_[0]->{cn} } );
        is( $r->{$id}, $v, "$l: get_key_from_all_sessions with a code ref" );
        $r = $class->get_key_from_all_sessions( $args, ['cn'] );
        is( $r->{$id}->{cn}, $v, "$l: get_key_from_all_sessions with fields" );
        $r = $class->searchOn( $args, 'uid', 'u8' );
        is( $r->{$id}->{cn}, $v, "$l: searchOn" );
        $r = $class->searchOn( $args, 'uid', 'u8', 'cn' );
        is( $r->{$id}->{cn}, $v, "$l: searchOn with fields" );

        tie %session, $class, $id, $args;
        tied(%session)->delete;
    }
}

my $dir = tempdir( CLEANUP => 1 );

# File: sessions holding only Latin-1 characters are written in Latin-1,
# others in UTF-8
{
    local $SIG{__WARN__} = sub { warn @_ unless $_[0] =~ /^Wide character/ };
    require Apache::Session::Browseable::File;
    roundTrip(
        'File',
        'Apache::Session::Browseable::File',
        { Directory => $dir, LockDirectory => $dir },
        $latin, $wide
    );

    # Known limit: File writes Latin-1 bytes when every character of the
    # session is in the Latin-1 range. When those characters also form a
    # valid UTF-8 sequence, the bytes are read back decoded as UTF-8: the two
    # characters U+00C3 U+00A9 are read as the single character U+00E9. This
    # test pins the current behaviour, which is not the desired one.
    my $ambiguous = "\x{c3}\x{a9}lodie";
    my %session;
    tie %session, 'Apache::Session::Browseable::File', undef,
      { Directory => $dir, LockDirectory => $dir };
    $session{uid} = 'u8';
    $session{cn}  = $ambiguous;
    my $id = $session{_session_id};
    untie %session;
    tie %session, 'Apache::Session::Browseable::File', $id,
      { Directory => $dir, LockDirectory => $dir };
    is( $session{cn}, "\x{e9}lodie",
        'File: Latin-1 value valid as UTF-8 is read back decoded (known limit)'
    );
    tied(%session)->delete;
    untie %session;
}

SKIP: {
    skip 'DBD::SQLite is needed', 28
      unless eval { require DBI; require DBD::SQLite; 1 };
    require Apache::Session::Browseable::SQLite;
    my $ds  = "dbi:SQLite:$dir/sessions.db";
    my $dbh = DBI->connect( $ds, '', '', { RaiseError => 1 } );
    $dbh->do( 'CREATE TABLE sessions (id char(64) not null primary key,'
          . ' a_session text, uid text)' );
    roundTrip(
        'SQLite',
        'Apache::Session::Browseable::SQLite',
        { DataSource => $ds, Index => 'uid' },
        $latin, $wide
    );

    # Handle without sqlite_unicode: UTF-8 bytes are returned
    roundTrip(
        'SQLite handle',
        'Apache::Session::Browseable::SQLite',
        { DataSource => $ds, Handle => $dbh, Commit => 0, Index => 'uid' },
        $latin, $wide
    );
}

# Redis can't store characters above U+00FF. It stores Latin-1, so
# "\x{c3}\x{a9}" is stored as valid UTF-8: it must not be read as "\x{e9}"
SKIP: {
    skip 'Set REDIS_URL to run Redis tests', 23 unless $ENV{REDIS_URL};
    skip 'Redis module is needed', 23
      unless eval { require Apache::Session::Browseable::Redis; 1 };
    my $class = 'Apache::Session::Browseable::Redis';
    my $args  = {
        server   => $ENV{REDIS_URL},
        database => $ENV{REDIS_DBNUM} || 15,
        Index    => 'uid'
    };
    roundTrip( 'Redis', $class, $args, $latin, "\x{c3}\x{a9}" );

    # Index entry of the previous value must be removed on update
    my $redis = $class->_getRedis($args);
    foreach my $t (
        [ "m\x{e9}", 'toto' ],
        [ 'dwho',    'rtyler' ],
        [ 'dwho',    'rtyler', cn => $latin ],
      )
    {
        my ( $old, $new, %data ) = @$t;
        ( my $l = "$old -> $new" ) =~ s/[^ -~]/?/g;
        $l .= ' with non-ASCII data' if (%data);
        my @warn;
        local $SIG{__WARN__} = sub { push @warn, @_ };
        my %session;
        tie %session, $class, undef, $args;
        $session{uid} = $old;
        $session{$_} = $data{$_} foreach ( keys %data );
        my $id = $session{_session_id};
        untie %session;
        tie %session, $class, $id, $args;
        $session{uid} = $new;
        untie %session;
        ok( !$redis->sismember( "uid_$old", $id ), "Index $l: old removed" );
        ok( $redis->sismember( "uid_$new",  $id ), "Index $l: new added" );
        is_deeply( \@warn, [], "Index $l: no warning" );
        tie %session, $class, $id, $args;
        tied(%session)->delete;
    }
}

done_testing();
