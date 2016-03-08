package Apache::Session::Browseable::File;

use strict;

use Apache::Session;
use Apache::Session::Lock::File;
use Apache::Session::Browseable::Store::File;
use Apache::Session::Generate::SHA256;
use Apache::Session::Serialize::Storable;
use Apache::Session::Browseable::_common;
use Storable qw(thaw);

our $VERSION = '1.0';
our @ISA     = qw(Apache::Session Apache::Session::Browseable::_common);

sub populate {
    my $self = shift;

    $self->{object_store} = new Apache::Session::Browseable::Store::File $self;
    $self->{lock_manager} = new Apache::Session::Lock::File $self;
    $self->{generate}     = \&Apache::Session::Generate::SHA256::generate;
    $self->{validate}     = \&Apache::Session::Generate::SHA256::validate;
    $self->{serialize}    = \&Apache::Session::Serialize::Storable::serialize;
    $self->{unserialize}  = \&Apache::Session::Serialize::Storable::unserialize;

    return $self;
}

sub DESTROY {
    my $self = shift;

    $self->save;
    $self->{object_store}->close;
    $self->release_all_locks;
}

sub get_key_from_all_sessions {
    my $class = shift;
    my $args  = shift;
    my $data  = shift;
    $args->{Directory} ||= $Apache::Session::Store::File::Directory;

    unless ( opendir DIR, $args->{Directory} ) {
        die "Cannot open directory $args->{Directory}\n";
    }
    my @t =
      grep { -f "$args->{Directory}/$_" and /^[A-Za-z0-9@\-]+$/ } readdir(DIR);
    closedir DIR;
    my %res;
    for my $f (@t) {
        open F, "$args->{Directory}/$f";
        my $row = join '', <F>;
        if ( ref($data) eq 'CODE' ) {
            $res{$f} = &$data( thaw($row), $f );
        }
        elsif ($data) {
            $data = [$data] unless ( ref($data) );
            my $tmp = thaw($row);
            $res{$f}->{$_} = $tmp->{$_} foreach (@$data);
        }
        else {
            $res{$f} = thaw($row);
        }
    }
    return \%res;
}

1;
__END__

