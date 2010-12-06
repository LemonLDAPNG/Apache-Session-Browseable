package Apache::Session::Browseable::File;

use strict;

use Apache::Session;
use Apache::Session::Lock::File;
use Apache::Session::Browseable::Store::File;
use Apache::Session::Generate::MD5;
use Apache::Session::Serialize::Storable;
use Apache::Session::Browseable::DBI;

our $VERSION = '0.3';
our @ISA     = qw(Apache::Session);

sub populate {
    my $self = shift;

    $self->{object_store} = new Apache::Session::Browseable::Store::File $self;
    $self->{lock_manager} = new Apache::Session::Lock::File $self;
    $self->{generate}     = \&Apache::Session::Generate::MD5::generate;
    $self->{validate}     = \&Apache::Session::Generate::MD5::validate;
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

sub searchOn {
    my ( $class, $args, $selectField, $value, @fields ) = @_;

    my %res = ();
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
    return \%res;
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

=pod

=head1 NAME

Apache::Session::File - An implementation of Apache::Session

=head1 SYNOPSIS

 use Apache::Session::File;

 tie %hash, 'Apache::Session::File', $id, {
    Directory => '/tmp/sessions',
    LockDirectory   => '/var/lock/sessions',
 };

=head1 DESCRIPTION

This module is an implementation of Apache::Session.  It uses the File backing
store and the File locking scheme.  You must specify the directory for the
object store and the directory for locking in arguments to the constructor. See
the example, and the documentation for Apache::Session::Store::File and
Apache::Session::Lock::File.

=head1 AUTHOR

This module was written by Jeffrey William Baker <jwbaker@acm.org>.

=head1 SEE ALSO

L<Apache::Session::DB_File>, L<Apache::Session::Flex>,
L<Apache::Session::MySQL>, L<Apache::Session::Postgres>, L<Apache::Session>
