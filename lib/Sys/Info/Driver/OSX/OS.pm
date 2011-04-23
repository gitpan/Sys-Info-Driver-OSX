package Sys::Info::Driver::OSX::OS;
use strict;
use warnings;
use base qw( Sys::Info::Base );
use Carp qw( croak );
use Cwd;
use POSIX ();
use Sys::Info::Constants qw( LIN_REAL_NAME_FIELD );
use Sys::Info::Driver::OSX;

our $VERSION = '0.79';

my %OSVERSION;

my $EDITION = {
    # taken from Wikipedia
    0 => 'Cheetah',
    1 => 'Puma',
    2 => 'Jaguar',
    3 => 'Panther',
    4 => 'Tiger',
    5 => 'Leopard',
    6 => 'Snow Leopard',
    7 => 'Lion',
};

# unimplemented
sub logon_server {}

sub edition {
    my $self = shift->_populate_osversion;
    return $OSVERSION{RAW}->{EDITION};
}

sub tz {
    my $self = shift;
    return POSIX::strftime('%Z', localtime);
}

sub meta {
    my $self = shift;
    $self->_populate_osversion();

    require POSIX;
    require Sys::Info::Device;

    my $cpu       = Sys::Info::Device->new('CPU');
    my $arch      = ($cpu->identify)[0]->{architecture};
    my $physmem   = fsysctl('hw.memsize'); # physmem
    my $usermem   = fsysctl('hw.usermem');

    # XXX
    my %swap;
    @swap{ qw/ path size used / } = qw( TODO 0 0);
    $swap{path} = undef;

    my %info;

    $info{manufacturer}              = 'Apple Inc.';
    $info{build_type}                = undef;
    $info{owner}                     = undef;
    $info{organization}              = undef;
    $info{product_id}                = undef;
    $info{install_date}              = undef;
    $info{boot_device}               = undef;

    $info{physical_memory_total}     = $physmem / 1024;
    $info{physical_memory_available} = ( $physmem - $usermem ) / 1024;
    $info{page_file_total}           = $swap{size};
    $info{page_file_available}       = $swap{size} - $swap{used};

    # windows specific
    $info{windows_dir}               = undef;
    $info{system_dir}                = undef;

    $info{system_manufacturer}       = 'Apple Inc.';
    $info{system_model}              = undef;
    $info{system_type}               = sprintf '%s based Computer', $arch;

    $info{page_file_path}            = $swap{path};

    return %info;
}

sub tick_count {
    my $self = shift;
    return time - $self->uptime;
}

sub name {
    my($self, @args) = @_;
    $self->_populate_osversion;
    my %opt  = @args % 2 ? () : @args;
    my $id   = $opt{long} ? ($opt{edition} ? 'LONGNAME_EDITION' : 'LONGNAME')
             :              ($opt{edition} ? 'NAME_EDITION'     : 'NAME'    )
             ;
    return $OSVERSION{ $id };
}


sub version   { shift->_populate_osversion(); return $OSVERSION{VERSION}      }
sub build     { shift->_populate_osversion(); return $OSVERSION{RAW}->{BUILD} }

sub uptime {
    my $key   = 'kern.boottime';
    my $value = fsysctl $key;
    if ( $value =~ m<\A[{](.+?)[}]\s+?(.+?)\z>xms ) {
        my($data, $stamp) = ($1, $2);
        my %data = map {
                        map {
                            __PACKAGE__->trim($_)
                        } split m{=}xms
                    } split m{[,]}xms, $data;
        croak "sec key does not exist in $key" if ! exists $data{sec};
        return $data{sec};
    }
    croak "Bogus data returned from $key: $value";
}

# user methods
sub is_root {
    my $name = login_name();
    my $id   = POSIX::geteuid();
    my $gid  = POSIX::getegid();
    return 0 if $@;
    return 0 if ! defined $id || ! defined $gid;
    return $id == 0 && $gid == 0; # && $name eq 'root'; # $name is never root!
}

sub login_name {
    my($self, @args) = @_;
    my %opt   = @args % 2 ? () : @args;
    my $login = POSIX::getlogin() || return;
    my $rv    = eval { $opt{real} ? (getpwnam $login)[LIN_REAL_NAME_FIELD] : $login };
    $rv =~ s{ [,]{3,} \z }{}xms if $opt{real};
    return $rv;
}

sub node_name { return shift->uname->{nodename} }

sub domain_name { }

sub fs {
    my $self = shift;
    return unimplemented => 1;
}

sub bitness {
    my $self = shift;
    my($sw) = system_profiler( 'SPSoftwareDataType' );
    return if ref $sw ne 'HASH';
    return if ! exists $sw->{'64bit_kernel_and_kexts'};
    my $type = $sw->{'64bit_kernel_and_kexts'} || q{};
    return $type eq 'yes' ? 64 : 32;
}

# ------------------------[ P R I V A T E ]------------------------ #

sub _file_has_substr {
    my $self = shift;
    my $file = shift;
    my $str  = shift;
    return if ! -e $file || ! -f _;
    my $raw = $self->slurp( $file ) =~ m{$str}xms;
    return $raw;
}

sub _probe_edition {
    my($self, $v) = @_;
    my($major, $minor, $patch) = split m{[.]}xms, $v;
    return $EDITION->{ $minor };
}

sub _populate_osversion {
    return if %OSVERSION;
    my $self    = shift;
    require POSIX;
    my($sysname, $nodename, $release, $version, $machine) = POSIX::uname();

    # 'Darwin Kernel Version 10.5.0: Fri Nov  5 23:20:39 PDT 2010; root:xnu-1504.9.17~1/RELEASE_I386',
    my($stuff, $root) = split m{;}xms, $version, 2;
    my($name, $stamp) = split m{:}xms, $stuff, 2;
    $_ = __PACKAGE__->trim( $_ ) for $stuff, $root, $name, $stamp;

    my %sw_vers = sw_vers();

    my $build_date = $stamp ? $self->date2time( $stamp ) : undef;
    my $build      = $sw_vers{BuildVersion} || $stamp;
    my $edition    = $self->_probe_edition( $sw_vers{ProductVersion} || $release );

    $sysname = 'Mac OSX' if $sysname eq 'Darwin';

    %OSVERSION = (
        NAME             => $sysname,
        NAME_EDITION     => $edition ? "$sysname ($edition)" : $sysname,
        LONGNAME         => q{}, # will be set below
        LONGNAME_EDITION => q{}, # will be set below
        VERSION  => $sw_vers{ProductVersion} || $release,
        KERNEL   => undef,
        RAW      => {
                        BUILD      => defined $build      ? $build      : 0,
                        BUILD_DATE => defined $build_date ? $build_date : 0,
                        EDITION    => $edition,
                    },
    );

    $OSVERSION{LONGNAME}         = sprintf '%s %s',
                                   @OSVERSION{ qw/ NAME         VERSION / };
    $OSVERSION{LONGNAME_EDITION} = sprintf '%s %s',
                                   @OSVERSION{ qw/ NAME_EDITION VERSION / };
    return;
}

1;

__END__

=head1 NAME

Sys::Info::Driver::OSX::OS - OSX backend

=head1 SYNOPSIS

-

=head1 DESCRIPTION

This document describes version C<0.79> of C<Sys::Info::Driver::OSX::OS>
released on C<24 April 2011>.

-

=head1 METHODS

Please see L<Sys::Info::OS> for definitions of these methods and more.

=head2 build

=head2 domain_name

=head2 edition

=head2 fs

=head2 is_root

=head2 login_name

=head2 logon_server

=head2 meta

=head2 name

=head2 node_name

=head2 tick_count

=head2 tz

=head2 uptime

=head2 version

=head2 bitness

=head1 SEE ALSO

L<Sys::Info>, L<Sys::Info::OS>,
L<http://en.wikipedia.org/wiki/Mac_OS_X>,
L<http://stackoverflow.com/questions/3610424/determine-kernel-bitness-in-mac-os-x-10-6>.

=head1 AUTHOR

Burak Gursoy <burak@cpan.org>.

=head1 COPYRIGHT

Copyright 2010 - 2011 Burak Gursoy. All rights reserved.

=head1 LICENSE

This library is free software; you can redistribute it and/or modify 
it under the same terms as Perl itself, either Perl version 5.12.3 or, 
at your option, any later version of Perl 5 you may have available.

=cut
