package WTSI::NPG::HTS::TarPublisher;

use namespace::autoclean;

use English qw[-no_match_vars];
use File::Spec::Functions qw[abs2rel];
use Moose;
use MooseX::StrictConstructor;

use WTSI::NPG::HTS::TarManifest;
use WTSI::NPG::HTS::TarStream;

our $VERSION= '';

with qw[
         WTSI::DNAP::Utilities::Loggable
         WTSI::NPG::HTS::ChecksumCalculator
       ];

has 'remove_files' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 1,
   default       => 0,
   documentation => 'Enable GNU tar --remove-files option to remove the ' .
                    'original file once archived');

has 'tar_manifest' =>
  (isa           => 'WTSI::NPG::HTS::TarManifest',
   is            => 'ro',
   required      => 1,
   documentation => 'Manifest to be updates after the tar publishing ' .
                    'operation is complete');

has 'tar_bytes' =>
  (isa           => 'Int',
   is            => 'ro',
   required      => 1,
   default       => 1024 * 1024 * 1024 * 32,
   documentation => 'The maximum number of bytes that will be added to any ' .
                    'tar file');

has 'tar_capacity' =>
  (isa           => 'Int',
   is            => 'ro',
   required      => 1,
   default       => 1024 * 1024,
   documentation => 'The maximum number of files that will be added to any ' .
                    'tar file');

has 'tar_count' =>
  (isa           => 'Int',
   is            => 'rw',
   required      => 1,
   default       => 0,
   init_arg      => undef,
   documentation => 'The number of tar files published');

has 'tar_cwd' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 1,
   documentation => 'The CWD of the tar operation, used for the -C <dir> ' .
                    'CLI option of GNU tar');

has 'tar_path' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 1,
   documentation => 'The iRODS collection or filesystem directory path ' .
                    ' in which the tar file(s) will be created');

has 'tar_stream' =>
  (isa           => 'WTSI::NPG::HTS::TarStream',
   is            => 'rw',
   required      => 0,
   predicate     => 'has_tar_stream',
   clearer       => 'clear_tar_stream',
   init_arg      => undef,
   documentation => 'The currently used stream to an open tar file');

around BUILDARGS => sub {
  my ($orig, $class, @args) = @_;

  if (not ref $args[0]) {
    my %args = @args;

    my $manifest = WTSI::NPG::HTS::TarManifest->new
      (manifest_path => delete $args{manifest_path});

    return $class->$orig(tar_manifest => $manifest, %args);
  }
  else {
    return $class->$orig(@args);
  }
};

sub BUILD {
  my ($self) = @_;

  # Read any manifest of published files left by a previous process
  if ($self->tar_manifest->file_exists) {
    $self->tar_manifest->read_file;
  }

  return;
}

=head2 publish_file

  Arg [1]    : Absolute file path, Str.

  Example    : my $path = $obj->publish_file('/path/to/file');
  Description: Add a file to the current tar stream and return the
               path of the tar file to which it was added.
  Returntype : Str

=cut

sub publish_file {
  my ($self, $path) = @_;

  my $tar_dest;
  my $tar_file = sprintf '%s.%d.tar', $self->tar_path, $self->tar_count;

  if (not $self->has_tar_stream) {
    $self->info(sprintf q[Opening '%s' with capacity %d from tar CWD '%s'],
                $self->tar_path, $self->tar_capacity, $self->tar_cwd);

    $self->tar_stream(WTSI::NPG::HTS::TarStream->new
                      (tar_cwd      => $self->tar_cwd,
                       tar_file     => $tar_file,
                       remove_files => $self->remove_files));
    $self->tar_stream->open_stream;
  }

  if ($self->tar_stream->byte_count >= $self->tar_bytes) {
    $self->info(sprintf q['%s' reached capacity of %d bytes],
                $self->tar_stream->tar_file, $self->tar_bytes);
    $self->close_stream; # Pre-op check: file was not added
  }
  else {
    $self->debug(sprintf q[Adding '%s' to '%s'], $path, $self->tar_path);

    $self->tar_stream->add_file($path);
    $tar_dest = $tar_file;

    $self->debug(sprintf q[Capacity now at %d / %d files, %d / %d bytes],
                 $self->tar_stream->file_count, $self->tar_capacity,
                 $self->tar_stream->byte_count, $self->tar_bytes);

    if ($self->tar_stream->file_count >= $self->tar_capacity) {
      $self->info(sprintf q['%s' reached capacity of %d files],
                  $self->tar_stream->tar_file, $self->tar_capacity);
      $self->close_stream; # Post-op check: file was added
    }
  }

  return $tar_dest;
}

=head2 file_published

  Arg [1]    : Absolute file path, Str.

  Example    : $obj->file_published('/path/to/file');
  Description: Return true if file has been published successfully by this
               instance or a previous one.
  Returntype : Bool

=cut

sub file_published {
  my ($self, $path) = @_;

  defined $path or $self->logconfess('A defined path argument is required');
  $path =~ m{^/}msx or
    $self->logconfess("An absolute path argument is required: '$path'");

  my $ipath = abs2rel($path, $self->tar_cwd);
  my $published = 0;

  if ($self->tar_manifest->contains_item($ipath) or
      ($self->tar_in_progress and $self->tar_stream->file_added($path))) {
    $published = 1;
  }

  $self->debug("File '$path' published? ", ($published ? 'yes': 'no'));

  return $published;
}

=head2 file_updated

  Arg [1]    : Absolute file path, Str.

  Example    : $obj->file_updated('/path/to/file');
  Description: Return true if file has been published successfully more
               than once, with different checksums i.e. 'publish_file'
               has been called more than once and the file was changed
               between calls.
  Returntype : Bool

=cut

sub file_updated {
  my ($self, $path) = @_;

  defined $path or $self->logconfess('A defined path argument is required');
  $path =~ m{^/}msx or
    $self->logconfess("An absolute path argument is required: '$path'");

  my $ipath = abs2rel($path, $self->tar_cwd);

  my $updated = 0;
  if ($self->tar_manifest->contains_item($ipath)) {
    $self->debug("Manifest contains record of '$path' added previously");

    my $prev_checksum = $self->tar_manifest->get_item($ipath)->checksum;
    my $curr_checksum = $self->calculate_checksum($path);
    if ($curr_checksum ne $prev_checksum) {
      $self->debug("File '$path' updated during publication ",
                   "from '$prev_checksum' to '$curr_checksum'");
      $updated = 1;
    }
    else {
      $self->debug("Current checksum of '$path' '$curr_checksum' ",
                   "matches previous checksum '$prev_checksum'");
    }
  }
  elsif ($self->tar_in_progress and $self->tar_stream->file_updated($path)) {
    $self->debug("Tar stream contains record of '$path' added previously");

    my @checksums = $self->tar_stream->file_checksum_history($path);
    $self->debug("Checksum history of '$path': [",
                 join(q[, ], @checksums), ']');
    $updated = 1;
  }

  return $updated;
}

=head2 tar_in_progress

  Arg [1]    : None.

  Example    : $obj->tar_in_progress;
  Description: Return true if a tar stream is currently open and has been
               used for at least one file.
  Returntype : Bool

=cut

sub tar_in_progress {
  my ($self) = @_;

  return ($self->has_tar_stream and $self->tar_stream->file_count > 0);
}

sub stream_elapsed_time {
  my ($self) = @_;

  my $elapsed = 0;
  if ($self->has_tar_stream) {
    my $now  = time;
    $elapsed = $now - $self->tar_stream->time_started->epoch;
  }

  return $elapsed;
}

=head2 close_stream

  Arg [1]    : None

  Example    : $obj->close_stream
  Description: Close any current stream safely, incrementing the tar count
               if appropriate.
  Returntype : Undef

=cut

sub close_stream {
  my ($self) = @_;

  if ($self->tar_in_progress) {
    $self->tar_stream->close_stream;
    $self->tar_count($self->tar_count + 1);
    my $tar_stream = $self->tar_stream;
    my $tar_path   = $tar_stream->tar_file;

    foreach my $file_path ($tar_stream->file_paths) {
      my $checksum  = $tar_stream->file_checksum($file_path);
      my $item_path = $tar_stream->item_path($file_path);
      $self->tar_manifest->add_item($tar_path, $item_path, $checksum);
    }
    $self->tar_manifest->update_file;

    $self->clear_tar_stream;

    my $tar_file = sprintf '%s.%d.tar', $self->tar_path, $self->tar_count;
    $self->info("Closed tar file '$tar_file'");
  }

  return;
}

__PACKAGE__->meta->make_immutable;

no Moose;

1;

__END__

=head1 NAME

WTSI::NPG::HTS::TarPublisher

=head1 DESCRIPTION

Publishes files to iRODS, archiving them in sequentially numbered tar
files on-the-fly. The capacity of each tar file is determined by
setting the 'tar_capacity' attribute and when one tar file is full, it
is closed automaticallyt and a new file opened. The number of tar
files created during the lifetime of the TarPublisher may be found
from the 'tar_count' attribute, which is automatically incremented
when each tar file is closed successfully.

A record of which local file is stored in each tar file is saved in a
local manifest file, which is updated only after each tar file is
closed successfully. The manifest serves to allow restarting a large
archiving operation. If the manifest is present when the TarPublisher
is created, it will be read. Attempts to publish any local file
already present in the manifest will be skipped. The manifest will
continue to be updated and saved when each subsequent tar file is
closed successfully.

The manifest is a text file containing one row per local file
archived, associating that file with a tar file in iRODS:

<Tar file path in iRODS><tab><Local file path>

=head1 AUTHOR

Keith James <kdj@sanger.ac.uk>

=head1 COPYRIGHT AND DISCLAIMER

Copyright (C) 2017 Genome Research Limited. All Rights Reserved.

This program is free software: you can redistribute it and/or modify
it under the terms of the Perl Artistic License or the GNU General
Public License as published by the Free Software Foundation, either
version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

=cut
