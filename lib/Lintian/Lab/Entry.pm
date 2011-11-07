# Lintian::Lab::Entry -- Perl laboratory entry for lintian

# Copyright (C) 2011 Niels Thykier <niels@thykier.net>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, you can find it on the World Wide
# Web at http://www.gnu.org/copyleft/gpl.html, or write to the Free
# Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston,
# MA 02110-1301, USA.


package Lintian::Lab::Entry;

=head1 NAME

Lintian::Lab::Entry - A package inside the Lab

=head1 SYNOPSIS

 use Lintian::Lab;
 
 my $lab = Lintian::Lab->new ("dir", "dist");
 my $lpkg = $lab->get_package ("name", "version", "arch", "type", "path");
 
 # create the entry if it does not exist
 $lpkg->create unless $lpkg->exists;
 
 # Remove package from lab.
 $lpkg->remove;

=head1 DESCRIPTION

... FIXME ?

=head2 METHODS

=over 4

=cut

use base qw(Lintian::Processable Class::Accessor Exporter);

use strict;
use warnings;

use Carp qw(croak);
use File::Spec;

use Cwd();

use Lintian::Lab;

use Util qw(delete_dir read_dpkg_control get_dsc_info);

# This is the entry format version - this changes whenever the layout of
# entries changes.  This differs from LAB_FORMAT in that LAB_FORMAT
# presents the things "outside" the entry.
use constant LAB_ENTRY_FORMAT => 1;

our (@EXPORT, @EXPORT_OK, %EXPORT_TAGS);

@EXPORT = ();
%EXPORT_TAGS = (
    constants => [qw(LAB_FORMAT_ENTRY)],
);
@EXPORT_OK = (
    @{ $EXPORT_TAGS{constants} }
);

# private constructor (called by Lintian::Lab)
sub _new {
    my ($type, $lab, $pkg_name, $pkg_version, $pkg_arch, $pkg_type, $pkg_path, $pkg_src, $pkg_src_version, $base_dir) = @_;
    my $self = {};
    bless $self, $type;
    $self->{pkg_name}        = $pkg_name;
    $self->{pkg_version}     = $pkg_version;
    $self->{pkg_type}        = $pkg_type;
    $self->{pkg_src}         = $pkg_src;
    $self->{pkg_src_version} = $pkg_src_version;
    $self->{lab}             = $lab;
    $self->{info}            = undef; # load on demand.
    $self->{coll}            = {};
    if ($pkg_type ne 'source') {
        $self->{pkg_arch} = $pkg_arch;
    } else {
        $self->{pkg_arch} = 'source';
    }

    $self->{base_dir} = $base_dir;

    if (defined $pkg_path) {
        croak "$pkg_path does not exist." unless -e $pkg_path;
    } else {
        # This error should not happen unless someone (read: me) breaks
        # Lintian::Lab::get_package
        croak "$pkg_name $pkg_type ($pkg_version) [$pkg_arch] does not exists"
            unless $self->exists;
        my $link;
        $link = 'deb' if $pkg_type eq 'binary' or $pkg_type eq 'udeb';
        $link = 'dsc' if $pkg_type eq 'source';
        $link = 'changes' if $pkg_type eq 'changes';

        croak "Unknown package type $pkg_type" unless $link;
        # Resolve the link if possible, but else just fall back to the link
        # - this is not safe in case of a "delete and create", but if
        #   abs_path fails odds are the package cannot be read anyway.
        $pkg_path = Cwd::abs_path("$base_dir/$link") // "$base_dir/$link";
    }

    $self->{pkg_path} = $pkg_path;


    $self->_init();
    return $self;
}

=item $lpkg->base_dir

Returns the base directory of this package inside the lab.

=cut

Lintian::Lab::Entry->mk_ro_accessors (qw(base_dir));

=item $lpkg->lab_pkg

Return $lpkg.  This method is here to simplify using a
L::Lab::Entry as a replacement for L::Processable::Package.

=cut

sub lab_pkg {
    my ($self) = @_;
    return $self;
}

=item $lpkg->info

Returns the L<Lintian::Collect|info> object associated with this entry.

Overrides info from L<Lintian::Processable>.

=cut

sub info {
    my ($self) = @_;
    my $info;
    croak 'Cannot load info, extry does not exist' unless $self->exists;
    $info = $self->{info};
    if ( ! defined $info ) {
        $info = Lintian::Collect->new ($self->pkg_name, $self->pkg_type, $self->base_dir);
        $self->{info} = $info;
    }
    return $info;
}


=item $lpkg->clear_cache

Clears any caches held; this includes discarding the L<Lintian::Collect|info> object.

Overrides clear_cache from L<Lintian::Processable>.

=cut

sub clear_cache {
    my ($self) = @_;
    delete $self->{info};
}

=item $lpkg->remove

Removes all unpacked parts of the package in the lab.  Returns a truth
value if successful.

=cut

sub remove {
    my ($self) = @_;
    my $basedir = $self->{base_dir};
    return 1 if( ! -e $basedir);
    $self->clear_cache;
    unless(delete_dir($basedir)) {
        return 0;
    }
    $self->{lab}->_entry_removed ($self);
    return 1;
}

=item $lpkg->exists

Returns a truth value if the lab-entry exists.

=cut

sub exists {
    my ($self) = @_;
    my $pkg_type = $self->{pkg_type};
    my $base_dir = $self->{base_dir};

    # Check if the relevant symlink exists.
    if ($pkg_type eq 'changes'){
        return 1 if -l "$base_dir/changes";
    } elsif ($pkg_type eq 'binary' or $pkg_type eq 'udeb') {
        return 1 if -l "$base_dir/deb";
    } elsif ($pkg_type eq 'source'){
        return 1 if -l "$base_dir/dsc";
    }

    # No unpack level and no symlink => the entry does not
    # exist or it is too broken in its current state.
    return 0;
}

=item $lpkg->create

Creates a minimum lab-entry, in which collections and checks
can be run.  Note if it already exists, then this will do
nothing.

=cut

sub create {
    my ($self) = @_;
    my $pkg_type = $self->{pkg_type};
    my $base_dir = $self->{base_dir};
    my $pkg_path = $self->{pkg_path};
    my $lab      = $self->{lab};
    my $link;
    my $madedir = 0;
    # It already exists.
    return 1 if $self->exists;

    unless (-d $base_dir) {
        # In the pool we may have to create multiple directories. On
        # error we only remove the "top dir" and that is enough.
        system ('mkdir', '-p', $base_dir) == 0
            or croak "mkdir -p $base_dir failed";
        $madedir = 1;
    }
    if ($pkg_type eq 'changes'){
        $link = "$base_dir/changes";
    } elsif ($pkg_type eq 'binary' or $pkg_type eq 'udeb') {
        $link = "$base_dir/deb";
    } elsif ($pkg_type eq 'source'){
        $link = "$base_dir/dsc";
    } else {
        croak "create cannot handle $pkg_type";
    }
    unless (symlink ($pkg_path, $link)){
        my $err = $!;
        # "undo" the mkdir if the symlink fails.
        rmdir $base_dir  if $madedir;
        $! = $err;
        croak "symlinking $pkg_path failed: $!";
    }
    if ($pkg_type eq 'source'){
        # If it is a source package, pull in all the related files
        #  - else unpacked will fail or we would need a separate
        #    collection for the symlinking.
        my $data = get_dsc_info($pkg_path);
        my (undef, $dir, undef) = File::Spec->splitpath($pkg_path);
        for my $fs (split(m/\n/o,$data->{'files'})) {
            $fs =~ s/^\s*//o;
            next if $fs eq '';
            my @t = split(/\s+/o,$fs);
            next if ($t[2] =~ m,/,o);
            symlink("$dir/$t[2]", "$base_dir/$t[2]")
                or croak("cannot symlink file $t[2]: $!");
        }
    }
    $lab->_entry_created ($self);
    return 1;
}

=item $lpkg->coll_version ($coll)

Returns the version of the collection named $coll, if that
$coll has been marked as finished.

Returns the empty string if $coll has not been marked as finished.

Note: The version can be 0.

=cut

sub coll_version {
    my ($self, $coll) = @_;
    return $self->{coll}->{$coll}//'';
}

=item $lpkg->is_coll_finished ($coll, $version)

Returns a truth value if the collection $coll has been completed and
its version is at least $version.  The versions are assumed to be
integers (the comparision is performed with ">=").

This returns 0 if the collection $coll has not been marked as
finished.

=cut

sub is_coll_finished {
    my ($self, $coll, $version) = @_;
    my $c = $self->coll_version ($coll);
    return 0 if $c eq '';
    return $c >= $version;
}

# $lpkg->_mark_coll_finished ($coll, $version)
#
# non-public method to mark a collection as complete
sub _mark_coll_finished {
    my ($self, $coll, $version) = @_;
    $self->{coll}->{$coll} = $version;
    return 1;
}

# $lpkg->_clear_coll_status ($coll)
#
# Removes the notion that $coll has been finished.
sub _clear_coll_status {
    my ($self, $coll) = @_;
    delete $self->{coll}->{$coll};
    return 1;
}

=item $lpkg->update_status_file ()

Flushes the cached changes of which collections have been completed.

This should also be called for new entries to create the status file.

=cut

sub update_status_file {
    my ($self) = @_;
    my $file;
    my @sc;

    unless ($self->exists) {
        $! = "Entry does not exists";
        return 0;
    }

    $file = $self->base_dir () . '/.lintian-status';
    open my $sfd, '>', $file or return 0;
    print $sfd 'Lab-Entry-Format: ' . LAB_ENTRY_FORMAT . "\n";
    # Basic package meta-data - this is redundant, but having it may
    # greatly simplify a migration or detecting a broken lab later.
    print $sfd 'Package: ' . $self->pkg_name, "\n";
    print $sfd 'Version: ' . $self->pkg_version, "\n";
    print $sfd 'Architecture: ' . $self->pkg_arch, "\n" if $self->pkg_type ne 'source';
    print $sfd 'Package-Type: ' . $self->pkg_type, "\n";

    @sc = sort keys %{ $self->{coll} };
    print $sfd "Collections: \n";
    print $sfd ' ' . join (",\n ", map { "$_=$self->{coll}->{$_}" } @sc);
    print $sfd "\n\n";
    close $sfd or return 0;
    return 1;
}

sub _init {
    my ($self) = @_;
    my $base_dir = $self->base_dir;
    my @data;
    my $head;
    my $coll;
    return unless $self->exists;
    return unless -e "$base_dir/.lintian-status";
    @data = read_dpkg_control ("$base_dir/.lintian-status");
    $head = $data[0];

    # Check that we know the format.
    return unless (LAB_ENTRY_FORMAT eq ($head->{'lab-entry-format'}//'') );

    $coll = $head->{'collections'}//'';
    $coll =~ s/\n/ /go;
    foreach my $c (split m/\s*,\s*+/o, $coll) {
        my ($cname, $cver) = split m/\s*=\s*/, $c;
        $self->{coll}->{$cname} = $cver;
    }
}

=back

=head1 AUTHOR

Niels Thykier <niels@thykier.net>

=cut

1;

# Local Variables:
# indent-tabs-mode: nil
# cperl-indent-level: 4
# End:
# vim: syntax=perl sw=4 sts=4 sr et