# SQL correctness tests of Apache::Session::Browseable::DBI using SQLite

use strict;
use warnings;
use Test::More;
use File::Temp qw(mktemp);

my $dbfile = mktemp('tmp.db_XXXX');

plan skip_all => "DBD::SQLite is needed for this test"
  unless eval {
    require DBI;
    require DBD::SQLite;
    1;
  };

my $dbh = DBI->connect( "dbi:SQLite:dbname=$dbfile", "", "",
    { RaiseError => 1, PrintError => 0 } );
$dbh->do( 'CREATE TABLE sessions(id char(64) not null primary key,'
      . 'a_session text,_utime text,_lastSeen text,_session_kind text,uid text)'
);

my $class = 'Apache::Session::Browseable::SQLite';
use_ok($class);

my $args = {
    DataSource => "dbi:SQLite:$dbfile",
    Index      => '_utime _lastSeen _session_kind uid',
};

sub newSession {
    my %data = @_;
    my %session;
    tie %session, $class, undef, $args;
    $session{$_} = $data{$_} foreach ( keys %data );
    my $id = $session{_session_id};
    untie %session;
    return $id;
}

sub reset_sessions {
    $dbh->do('DELETE FROM sessions');
    my %ids;
    while (@_) {
        my ( $name, $data ) = splice @_, 0, 2;
        $ids{$name} = newSession(%$data);
    }
    return \%ids;
}

sub remaining {
    my ($ids) = @_;
    my $all   = $class->get_key_from_all_sessions($args);
    my %rev   = reverse %$ids;
    return join ',', sort map { $rev{$_} } keys %$all;
}

sub quiet(&) {
    my ($code) = @_;
    local *STDERR;
    my $err = '';
    open STDERR, '>', \$err;
    return $code->();
}

# Like quiet(), but also returns what was written to STDERR
sub quiet_err(&) {
    my ($code) = @_;
    local *STDERR;
    my $err = '';
    open STDERR, '>', \$err;
    my $res = $code->();
    return ( $res, $err );
}

my ( $ids, $res, @res, $rule, $ret, $err );

# get_key_from_all_sessions reads sessions by batches
{
    no warnings 'once';
    local $Apache::Session::Browseable::_common::BatchSize = 2;
    my $queries = 0;
    my $cdbh    = $class->_classDbh($args);
    local $cdbh->{Callbacks} =
      { ChildCallbacks => { execute => sub { $queries++; return } } };
    foreach my $n ( 4, 5 ) {
        $ids = reset_sessions( map { ( "s$_" => { uid => "u$_" } ) } 1 .. $n );
        $queries = 0;
        my $calls = 0;
        $res = $class->get_key_from_all_sessions( $args,
            sub { $calls++; $_[0]->{uid} } );
        is( $calls, $n, "$n sessions by batches: callback called for each" );
        is_deeply(
            $res,
            { map { ( $ids->{"s$_"} => "u$_" ) } 1 .. $n },
            "$n sessions by batches: all sessions returned"
        );
        is( $queries, 3, "$n sessions by batches: 3 queries" );
        $res = $class->get_key_from_all_sessions($args);
        is(
            join( ',', sort map { $_->{uid} } values %$res ),
            join( ',', map { "u$_" } 1 .. $n ),
            "$n sessions by batches: all sessions returned without callback"
        );
    }
}

# 11. Invalid batch sizes fall back to the default one
{
    no warnings 'once';
    $ids = reset_sessions( map { ( "s$_" => { uid => "u$_" } ) } 1 .. 3 );
    foreach my $size ( 0, -1, 'abc', undef, 1_000_001, '9' x 26 ) {
        local $Apache::Session::Browseable::_common::BatchSize = $size;
        my $name = defined $size ? "'$size'" : 'undef';
        $res = eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm 10;
            my $r = $class->get_key_from_all_sessions($args);
            alarm 0;
            $r;
        };
        alarm 0;
        is( $@, '', "BatchSize $name: terminates" );
        is( join( ',', sort map { $_->{uid} } values %{ $res || {} } ),
            'u1,u2,u3', "BatchSize $name: all sessions returned" );
    }
}

# 12. Subclass without its own populate()
{

    package My::SQLiteSubclass;
    our @ISA = ('Apache::Session::Browseable::SQLite');
}
$res = eval { My::SQLiteSubclass->get_key_from_all_sessions($args) };
is( $@, '', 'Subclass without populate: no error' );
is( join( ',', sort map { $_->{uid} } values %{ $res || {} } ),
    'u1,u2,u3', 'Subclass without populate: all sessions returned' );
$res = eval {
    My::SQLiteSubclass->get_key_from_all_sessions( $args,
        sub { $_[0]->{uid} } );
};
is( join( ',', sort values %{ $res || {} } ),
    'u1,u2,u3', 'Subclass without populate: callback called' );

# "not" value containing a quote is bound, not interpolated
$ids = reset_sessions(
    obrien => { _utime => 100, _session_kind => "O'Brien" },
    other  => { _utime => 100, _session_kind => 'x' },
    recent => { _utime => 300, _session_kind => 'x' },
);
$rule = { or => { _utime => 250 }, not => { _session_kind => "O'Brien" } };
ok( $class->deleteIfLowerThan( $args, $rule ), 'not with quote' );
is( remaining($ids), 'obrien,recent', 'not with quote: "other" deleted' );
is( $rule->{not}->{_session_kind}, "O'Brien", 'rule is not modified' );

$ids = reset_sessions(
    a      => { _utime => 100, _session_kind => 'a' },
    recent => { _utime => 300, _session_kind => 'x' },
);
ok(
    $class->deleteIfLowerThan(
        $args,
        { or => { _utime => 250 }, not => { _session_kind => "x' OR '1'='1" } }
    ),
    'not with injection attempt'
);
is( remaining($ids), 'recent', 'not with injection attempt: no injection' );

# deleteIfLowerThan with a non numeric threshold does nothing
$ids = reset_sessions(
    a => { _utime => 100, _session_kind => 'SSO' },
    b => { _utime => 100, _session_kind => 'Persistent' },
);
foreach my $bad ( '100 OR 1=1', '1e3', '', undef ) {
    is(
        quiet {
            eval {
                $class->deleteIfLowerThan( $args,
                    { or => { _utime => $bad } } );
            }
        },
        0,
        'non numeric threshold: returns 0 ('
          . ( defined $bad ? "'$bad'" : 'undef' ) . ')'
    );
}
is(
    quiet {
        $class->deleteIfLowerThan( $args,
            { and => { _utime => 250, _lastSeen => 'x' } } );
    },
    0,
    'non numeric "and" threshold: returns 0'
);
is(
    quiet {
        $class->deleteIfLowerThan( $args,
            { or => { _utime => "\x{0661}\x{0662}" } } );
    },
    0,
    'non ASCII digits threshold: returns 0'
);
is( remaining($ids), 'a,b', 'non numeric threshold: nothing deleted' );

# deleteIfLowerThan with a decimal or negative threshold
ok( $class->deleteIfLowerThan( $args, { or => { _utime => '100.5' } } ),
    'decimal threshold accepted' );
ok( $class->deleteIfLowerThan( $args, { or => { _utime => '-1' } } ),
    'negative threshold accepted' );

# searchLt() and searchGt(): indexed fields are compared in SQL, other
# ones in Perl. Both compare "abc" as 0 and "250x" as 250. Sessions without
# the field are never returned
$ids = reset_sessions(
    a    => { _utime => 100,    n => 100 },
    b    => { _utime => 200,    n => 200 },
    c    => { _utime => 300,    n => 300 },
    str  => { _utime => 'abc',  n => 'abc' },
    pre  => { _utime => '250x', n => '250x' },
    none => { uid    => 'none' },
);
my %rev = reverse %$ids;
my @sql;
{
    my $cdbh = $class->_classDbh($args);
    local $cdbh->{Callbacks} = {
        prepare => sub { push @sql, $_[1]; return }
    };
    foreach (
        [ searchLt =>  250,    'a,b,str' ],
        [ searchGt =>  200,    'c,pre' ],
        [ searchLt =>  1,      'str' ],
        [ searchGt => -1,      'a,b,c,pre,str' ],
        [ searchLt => '250.5', 'a,b,pre,str' ],
      )
    {
        my ( $m, $v, $expected ) = @$_;
        foreach my $f (qw(_utime n)) {
            @sql = ();
            $res = $class->$m( $args, $f, $v );
            is( join( ',', sort map { $rev{$_} } keys %$res ),
                $expected, "$m $f $v" );
            my $op = $m eq 'searchLt' ? '<' : '>';
            if ( $f eq '_utime' ) {
                is_deeply(
                    \@sql,
                    [
"SELECT id,a_session from sessions where cast(_utime as integer) $op $v"
                    ],
                    "$m $f $v: compared in SQL"
                );
            }
            else {
                unlike( join( "\n", @sql ),
                    qr/cast\(/, "$m $f $v: compared in Perl" );
            }
        }
    }
}
$res = $class->searchLt( $args, '_utime', 150 );
is( $res->{ $ids->{a} }->{n}, 100, 'searchLt without fields returns sessions' );
foreach my $f (qw(_utime n)) {
    $res = $class->searchGt( $args, $f, 250, $f, 'uid' );
    is_deeply( [ map { $_->{$f} } values %$res ],
        [300], "searchGt $f with fields: 1 session" );
    is(
        join( ',', sort grep { $_ ne 'id' } keys %{ ( values %$res )[0] } ),
        join( ',', sort $f, 'uid' ),
        "searchGt $f with fields: requested fields"
    );
}
foreach my $bad ( '100 OR 1=1', '1e3', '', undef, 'abc' ) {
    foreach my $m (qw(searchLt searchGt)) {
        $res = quiet { $class->$m( $args, '_utime', $bad ) };
        is_deeply( $res, {},
            "$m with value " . ( $bad // 'undef' ) . ': nothing returned' );
    }
}

# Values that are not integers differ: SQL keeps only an integer prefix
# (12.7 is 12, 1e3 is 1), Perl compares the numeric value
$ids = reset_sessions(
    dec => { _utime => '12.7', n => '12.7' },
    exp => { _utime => '1e3',  n => '1e3' },
);
%rev = reverse %$ids;
$res = $class->searchGt( $args, '_utime', 12 );
is( join( ',', sort map { $rev{$_} } keys %$res ),
    '', 'searchGt in SQL: integer prefix' );
$res = $class->searchGt( $args, 'n', 12 );
is( join( ',', sort map { $rev{$_} } keys %$res ),
    'dec,exp', 'searchGt in Perl: numeric value' );

done_testing();

END {
    unlink $dbfile if ( $dbfile and -e $dbfile );
}
