package WTSI::NPG::HTS::PacBio::RunPublisher;

use namespace::autoclean;
use Data::Dump qw[pp];
use English qw[-no_match_vars];
use File::Basename;
use File::Spec::Functions qw[catdir catfile splitdir];
use List::AllUtils qw[any first];
use Moose;
use MooseX::StrictConstructor;
use Try::Tiny;

use WTSI::DNAP::Utilities::Params qw[function_params];
use WTSI::NPG::HTS::BatchPublisher;
use WTSI::NPG::HTS::PacBio::DataObjectFactory;
use WTSI::NPG::HTS::PacBio::MetaXMLParser;
use WTSI::NPG::iRODS::Metadata;
use WTSI::NPG::iRODS;

with qw[
         WTSI::DNAP::Utilities::Loggable
         WTSI::NPG::HTS::PathLister
         WTSI::NPG::HTS::PacBio::Annotator
         WTSI::NPG::HTS::PacBio::MetaQuery
       ];

our $VERSION = '';

# Default
our $DEFAULT_ROOT_COLL    = '/seq/pacbio';

# The default SMRT analysis results directory name
our $ANALYSIS_DIR = 'Analysis_Results';

# Well directory pattern
our $WELL_DIRECTORY_PATTERN = '\d+_\d+$';

has 'irods' =>
  (isa           => 'WTSI::NPG::iRODS',
   is            => 'ro',
   required      => 1,
   documentation => 'An iRODS handle to run searches and perform updates');

has 'obj_factory' =>
  (does          => 'WTSI::NPG::HTS::DataObjectFactory',
   is            => 'ro',
   required      => 1,
   lazy          => 1,
   builder       => '_build_obj_factory',
   documentation => 'A factory building data objects from files');

has 'runfolder_path' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 1,
   documentation => 'PacBio runfolder path');

has 'batch_publisher' =>
  (is            => 'ro',
   isa           => 'WTSI::NPG::HTS::BatchPublisher',
   required      => 1,
   lazy          => 1,
   builder       => '_build_batch_publisher',
   documentation => 'A publisher implementation capable to handling errors');

has 'restart_file' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 1,
   lazy          => 1,
   builder       => '_build_restart_file',
   documentation => 'A file containing a list of files for which ' .
                    'publication failed');

has 'dest_collection' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 1,
   lazy          => 1,
   builder       => '_build_dest_collection',
   documentation => 'The destination collection within iRODS to store data');

has 'directory_pattern' =>
  (isa           => 'Str',
   is            => 'ro',
   init_arg      => undef,
   lazy          => 1,
   builder       => '_build_directory_pattern',
   documentation => 'Well directory pattern');

has 'force' =>
  (isa           => 'Bool',
   is            => 'ro',
   required      => 0,
   default       => 0,
   documentation => 'Force re-publication of files that have been published');

sub run_name {
  my ($self) = @_;

  return first { $_ ne q[] } reverse splitdir($self->runfolder_path);
}

=head2 smrt_names

  Arg [1]    : None

  Example    : my @names = $pub->smrt_names;
  Description: Return the SMRT cell names within a run, sorted lexically.
  Returntype : Array[Str]

=cut

sub smrt_names {
  my ($self) = @_;

  my $dir_pattern = $self->directory_pattern;
  my @dirs = grep { -d } $self->list_directory($self->runfolder_path,
                                               $dir_pattern);
  my @names = sort map { first { $_ ne q[] } reverse splitdir($_) } @dirs;

  return @names;
}

=head2 smrt_look_indices

  Arg [1]    : SMRT cell name, Str.

  Example    : my @indices = $pub->smrt_look_indices('A01_1');
  Description: Return look indices given a cell name.
  Returntype : Array[Int]

=cut

sub smrt_look_indices {
  my ($self, $smrt_name) = @_;

  my $name = $self->_check_smrt_name($smrt_name);

  my $file_pattern = '_p\d+[.]metadata[.]xml$';
  my @files = $self->list_directory($self->smrt_path($name), $file_pattern);

  my @look_indices;
  foreach my $file (@files) {
    if ($file =~ m{_s(\d+)_p\d+[.]metadata[.]xml$}msx) {
      push @look_indices, $1;
    }
  }

  return @look_indices;
}

=head2 smrt_path

  Arg [1]    : SMRT cell name, Str.

  Example    : my $path = $pub->smrt_path('A01_1');
  Description: Return the path to SMRT cell data within a run, given
               the cell name.
  Returntype : Str

=cut

sub smrt_path {
  my ($self, $smrt_name) = @_;

  my $name = $self->_check_smrt_name($smrt_name);
  return catdir($self->runfolder_path, $name);
}

=head2 smrt_analysis_path

  Arg [1]    : SMRT cell name, Str.

  Example    : my $path = $pub->smrt_analysis_path('A01_1');
  Description: Return the path to SMRT cell analysis results within a run,
               given the cell name.
  Returntype : Str

=cut

sub smrt_analysis_path {
  my ($self, $smrt_name) = @_;

  my $name = $self->_check_smrt_name($smrt_name);
  return catdir($self->smrt_path($name), $ANALYSIS_DIR);
}

=head2 list_basx_files

  Arg [1]    : SMRT cell name, Str.
  Arg [2]    : Look index, Int. Optional.

  Example    : $pub->list_basx_files('A01_1')
  Description: Return paths of all ba[s|x] files for the given SMRT cell.
               Calling this method will access the file system.
  Returntype : ArrayRef[Str]

=cut

sub list_basx_files {
  my ($self, $smrt_name, $look_index) = @_;

  my $name = $self->_check_smrt_name($smrt_name);
  my $look_pattern = q[];
  if (defined $look_index) {
    $look_pattern = sprintf '_s%s', $look_index;
  }

  my $file_pattern = sprintf '%s_p\d+([.]\d+)?[.]ba[sx][.]h5$', $look_pattern;

  return [$self->list_directory($self->smrt_analysis_path($name),
                                $file_pattern)];
}

=head2 list_sts_xml_files

  Arg [1]    : SMRT cell name, Str.
  Arg [2]    : Look index, Int. Optional.

  Example    : $pub->list_sts_xml_files('A01_1')
  Description: Return paths of all sts XML files for the given SMRT cell.
               Calling this method will access the file system.
  Returntype : ArrayRef[Str]

=cut

sub list_sts_xml_files {
  my ($self, $smrt_name, $look_index) = @_;

  my $name = $self->_check_smrt_name($smrt_name);
  my $look_pattern = q[];
  if (defined $look_index) {
    $look_pattern = sprintf '_s%s', $look_index;
  }

  my $file_pattern = sprintf '%s_p\d+[.]sts[.]xml$', $look_pattern;

  return [$self->list_directory($self->smrt_analysis_path($name),
                                $file_pattern)];
}

=head2 list_meta_xml_file

  Arg [1]    : SMRT cell name, Str.
  Arg [2]    : Look index, Int. Optional.

  Example    : $pub->list_meta_xml_file('A01_1')
  Description: Return the path of the metadata XML file for the given SMRT
               cell.  Calling this method will access the file system.
  Returntype : Str

=cut

sub list_meta_xml_file {
  my ($self, $smrt_name, $look_index) = @_;

  my $name = $self->_check_smrt_name($smrt_name);
  my $look_pattern = q[];
  if (defined $look_index) {
    $look_pattern = sprintf '_s%s', $look_index;
  }

  my $file_pattern = sprintf '%s_p\d+[.]metadata[.]xml$', $look_pattern;

  my @files = $self->list_directory($self->smrt_path($name), $file_pattern);

  my $num_files = scalar @files;
  if ($num_files == 0) {
    $self->logconfess('Failed to find an XML metadata file for ',
                      "SMRT cell '$smrt_name'");
  }
  if ($num_files > 1) {
    $self->logconfess("Found $num_files XML metadata files for ",
                      "SMRT cell '$smrt_name': ", pp(\@files));
  }

  return shift @files;
}

=head2 publish_files

  Arg [1]    : None

  Named args : smrt_names           ArrayRef[Str]. Optional.
               look_index           Int. Optional

  Example    : my ($num_files, $num_published, $num_errors) =
                 $pub->publish_files(smrt_names => ['A01_1', 'B01_1'],
                                     look_index => 1)
  Description: Publish all files to iRODS. If the smart_names argument is
               supplied, only those SMRT cells will be published. The default
               is to publish all SMRT cells. Return the number of files,
               the number published and the number of errors.
  Returntype : Array[Int]

=cut

{
  my $positional = 1;
  my @named      = qw[smrt_names look_index];
  my $params = function_params($positional, @named);

  sub publish_files {
    my ($self) = $params->parse(@_);

    my $smrt_names = $params->smrt_names || [$self->smrt_names];
    $self->info('Publishing files for SMRT cells: ', pp($smrt_names));

    my ($num_files, $num_processed, $num_errors) = (0, 0, 0);

    foreach my $smrt_name (@{$smrt_names}) {

      # There are no longer >1 look indices on runs. This code is to
      # support re-loading of any old data.
      my @look_indices = $self->smrt_look_indices($smrt_name);
      my $num_looks = scalar @look_indices;
      my $look_index = $params->look_index;

      if ($num_looks > 1) {
        if (not $params->look_index) {
          $self->logcroak("There are $num_looks look indices for SMRT cell ",
                          "'$smrt_name'; please select one to publish: ",
                          pp(\@look_indices));
        }
      }
      else {
        $look_index = $look_indices[0];
        $self->info("There is one look index '$look_index' ",
                    "for SMRT cell '$smrt_name'");
      }

      my ($nfx, $npx, $nex) =
        $self->publish_meta_xml_file($smrt_name, $look_index);
      my ($nfb, $npb, $neb) =
        $self->publish_basx_files($smrt_name, $look_index);
      my ($nfs, $nps, $nes) =
        $self->publish_sts_xml_files($smrt_name, $look_index);

      $num_files     += ($nfx + $nfb + $nfs);
      $num_processed += ($npx + $npb + $nps);
      $num_errors    += ($nex + $neb + $nes);
    }

    if ($num_errors > 0) {
      $self->error("Encountered errors on $num_errors / ",
                   "$num_processed files processed");
    }

    return ($num_files, $num_processed, $num_errors);
  }
}

=head2 publish_meta_xml_file

  Arg [1]    : None

  Named args : smrt_name            Str.
               look_index           Int. Optional if there is one look index,
                                    required if there is more than one.

  Example    : my ($num_files, $num_published, $num_errors) =
                 $pub->publish_meta_xml_file
  Description: Publish metadata XML file for a SMRT cell to iRODS. Return
               the number of files, the number published and the number
               of errors.
  Returntype : Array[Int]

=cut

sub publish_meta_xml_file {
  my ($self, $smrt_name, $look_index) = @_;

  my $files = [$self->list_meta_xml_file($smrt_name, $look_index)];
  my $dest_coll = catdir($self->dest_collection, $smrt_name);

  my ($num_files, $num_processed, $num_errors) =
    $self->_publish_files($files, $dest_coll);

  $self->info("Published $num_processed / $num_files metadata XML files ",
              "in SMRT cell '$smrt_name' with $num_errors errors");

  return ($num_files, $num_processed, $num_errors);
}

=head2 publish_basx_files

  Arg [1]    : None

  Named args : smrt_name            Str.
               look_index           Int. Optional if there is one look index,
                                    required if there is more than one.

  Example    : my ($num_files, $num_published, $num_errors) =
                 $pub->publish_basx_files
  Description: Publish bas and bax files for a SMRT cell to iRODS. Return
               the number of files, the number published and the number
               of errors.
  Returntype : Array[Int]

=cut

sub publish_basx_files {
  my ($self, $smrt_name, $look_index) = @_;

  my $files     = $self->list_basx_files($smrt_name, $look_index);
  my $dest_coll = catdir($self->dest_collection, $smrt_name, $ANALYSIS_DIR);

  my $metadata_file = $self->list_meta_xml_file($smrt_name, $look_index);
  $self->debug("Reading metadata from '$metadata_file'");

  my $metadata =
    WTSI::NPG::HTS::PacBio::MetaXMLParser->new->parse_file($metadata_file);

  # There will be 1 record for a non-multiplexed SMRT cell and >1
  # record for a multiplexed
  my @run_records = $self->find_pacbio_runs($metadata->run_name,
                                            $metadata->well_name);

  # R & D runs have no records in the ML warehouse
  my $is_r_and_d = @run_records ? 0 : 1;

  my ($num_files, $num_processed, $num_errors) = (0, 0, 0);

  # A production well will always have run_uuid and records in ML
  # warehouse. Production data are not published unless ML warehouse
  # records are present.
  if ($metadata->has_run_uuid && $is_r_and_d) {
    $self->error("Failed to publish $num_files bas/x files for run ",
                 $metadata->run_name, ' well ', $metadata->well_name ,
                 ' as data missing from ML warehouse');
    $num_files = $num_processed = $num_errors = scalar @{$files};
  }
  else {
    my @primary_avus   = $self->make_primary_metadata($metadata, $is_r_and_d);
    my @secondary_avus = $self->make_secondary_metadata(@run_records);
    my @extra_avus     = $self->make_avu($FILE_TYPE, 'bas');

    ($num_files, $num_processed, $num_errors) =
      $self->_publish_files($files, $dest_coll,
                            \@primary_avus, \@secondary_avus, \@extra_avus);
  }

  $self->info("Published $num_processed / $num_files bas/x files ",
              "in SMRT cell '$smrt_name' with $num_errors errors");

  return ($num_files, $num_processed, $num_errors);
}

=head2 publish_sts_xml_files

  Arg [1]    : None

  Named args : smrt_name            Str.
               look_index           Int. Optional if there is one look index,
                                    required if there is more than one.

  Example    : my ($num_files, $num_published, $num_errors) =
                 $pub->publish_sts_xml_files
  Description: Publish sts XML files for a SMRT cell to iRODS. Return
               the number of files, the number published and the number
               of errors.
  Returntype : Array[Int]

=cut

sub publish_sts_xml_files {
  my ($self, $smrt_name, $look_index) = @_;

  my $files = $self->list_sts_xml_files($smrt_name, $look_index);
  my $dest_coll = catdir($self->dest_collection, $smrt_name, $ANALYSIS_DIR);

  my ($num_files, $num_processed, $num_errors) =
    $self->_publish_files($files, $dest_coll);

  $self->info("Published $num_processed / $num_files sts XML files ",
              "in SMRT cell '$smrt_name' with $num_errors errors");

  return ($num_files, $num_processed, $num_errors);
}

sub write_restart_file {
  my ($self) = @_;

  $self->batch_publisher->write_state;
  return
}

## no critic (ProhibitManyArgs)
sub _publish_files {
  my ($self, $files, $dest_coll, $primary_avus, $secondary_avus,
      $extra_avus) = @_;

  $primary_avus   ||= [];
  $secondary_avus ||= [];
  $extra_avus     ||= [];

  ref $primary_avus eq 'ARRAY' or
    $self->logconfess('The primary_avus argument must be an ArrayRef');
  ref $secondary_avus eq 'ARRAY' or
    $self->logconfess('The secondary_avus argument must be an ArrayRef');

  my $primary_avus_callback = sub {
    return @{$primary_avus};
  };

  my $secondary_avus_callback = sub {
    return @{$secondary_avus};
  };

  my $extra_avus_callback = sub {
    return @{$extra_avus};
  };

  return $self->batch_publisher->publish_file_batch
    ($files, $dest_coll,
     $primary_avus_callback,
     $secondary_avus_callback,
     $extra_avus_callback);
}
## use critic

sub _build_dest_collection  {
  my ($self) = @_;

  return catdir($DEFAULT_ROOT_COLL, $self->run_name);
}

sub _build_batch_publisher {
  my ($self) = @_;

  return WTSI::NPG::HTS::BatchPublisher->new
    (force                  => $self->force,
     irods                  => $self->irods,
     obj_factory            => $self->obj_factory,
     state_file             => $self->restart_file,
     require_checksum_cache => []); ## no md5s precreated for PacBio
}

sub _build_restart_file {
  my ($self) = @_;

  return catfile($self->runfolder_path, 'published.json');
}

sub _build_directory_pattern{
   my ($self) = @_;

   return $WELL_DIRECTORY_PATTERN;
}

sub _build_obj_factory {
  my ($self) = @_;

  return WTSI::NPG::HTS::PacBio::DataObjectFactory->new(irods => $self->irods);
}

# Check that a SMRT cell name argument is given and valid
sub _check_smrt_name {
  my ($self, $smrt_name) = @_;

  defined $smrt_name or
    $self->logconfess('A defined smrt_name argument is required');
  any { $smrt_name eq $_ } $self->smrt_names or
    $self->logconfess("Invalid smrt_name argument '$smrt_name'");

  return $smrt_name;
}

__PACKAGE__->meta->make_immutable;

no Moose;

1;

__END__

=head1 NAME

WTSI::NPG::HTS::PacBio::RunPublisher

=head1 DESCRIPTION

Publishes metadata.xml, bax.h5, bas.h5 and sts.xml files to iRODS,
adds metadata and sets permissions.

An instance of RunPublisher is responsible for copying PacBio
sequencing data from the instrument run folder to a collection in
iRODS for a single, specific run.

Data files are divided into three categories:

 - basx files; HDF files of sequence data.
 - meta XML files; run metadata.
 - sts XML files; run metadata.

A RunPublisher provides methods to list the complement of these
categories and to copy ("publish") them. Each of these list or publish
operations may be restricted to a specific SMRT cell and look index
position.

As part of the copying process, metadata are added to, or updated on,
the files in iRODS. Following the metadata update, access permissions
are set. The information to do both of these operations is provided by
an instance of WTSI::DNAP::Warehouse::Schema.

If a run is published multiple times to the same destination
collection, the following take place:

 - the RunPublisher checks local (run folder) file checksums against
   remote (iRODS) checksums and will not make unnecessary updates

 - if a local file has changed, the copy in iRODS will be overwritten
   and additional metadata indicating the time of the update will be
   added

 - the RunPublisher will proceed to make metadata and permissions
   changes to synchronise with the metadata supplied by
   WTSI::DNAP::Warehouse::Schema, even if no files have been modified

=head1 AUTHOR

Guoying Qi E<lt>gq1@sanger.ac.ukE<gt>
Keith James E<lt>kdj@sanger.ac.ukE<gt>

=head1 COPYRIGHT AND DISCLAIMER

Copyright (C) 2011, 2016, 2017 Genome Research Limited. All Rights
Reserved.

This program is free software: you can redistribute it and/or modify
it under the terms of the Perl Artistic License or the GNU General
Public License as published by the Free Software Foundation, either
version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

=cut
