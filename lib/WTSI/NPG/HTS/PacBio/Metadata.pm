package WTSI::NPG::HTS::PacBio::Metadata;

use namespace::autoclean;
use Moose;
use MooseX::StrictConstructor;
use MooseX::Storage;

with Storage( 'traits' => ['OnlyWhenBuilt'],
              'format' => 'JSON',
              'io'     => 'File' );

our $VERSION = '';

has 'file_path' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 1,
   documentation => 'The path of the metadata XML file');

has 'run_name' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 1,
   documentation => 'The PacBio XML run name');

has 'ts_run_name' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 0,
   predicate     => 'has_ts_run_name',
   documentation => 'The timestamp run name');

has 'sample_load_name' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 1,
   documentation => 'The PacBio XML sample');

has 'well_name' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 1,
   documentation => 'The PacBio XML well name');

has 'instrument_name' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 1,
   documentation => 'The PacBio XML instrument name');

has 'collection_number' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 1,
   documentation => 'The PacBio XML collection number');

has 'cell_index' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 1,
   documentation => 'The PacBio XML cell index');

has 'movie_name' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 0,
   predicate     => 'has_movie_name',
   documentation => 'The PacBio movie name');

has 'set_number' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 0,
   predicate     => 'has_set_number',
   documentation => 'The PacBio XML set number');

has 'run_uuid' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 0,
   predicate     => 'has_run_uuid',
   documentation => 'The WTSI LIMS PacBio run UUID');

has 'results_folder' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 0,
   predicate     => 'has_results_folder',
   documentation => 'The results folder');

has 'is_ccs' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 0,
   predicate     => 'has_is_ccs',
   documentation => 'Is the PacBio data ccs');

has 'subreads_uuid' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 0,
   predicate     => 'has_subreads_uuid',
   documentation => 'The PacBio subreadset uuid');

has 'ccsreads_uuid' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 0,
   predicate     => 'has_ccsreads_uuid',
   documentation => 'The PacBio ccsreads uuid');

has 'version_info'  =>
  (isa           => 'HashRef',
   is            => 'ro',
   required      => 0,
   predicate     => 'has_version_info',
   documentation => 'The PacBio version info');


around BUILDARGS => sub {
  my $orig   = shift;
  my $class  = shift;

  my %params = ref $_[0] ? %{$_[0]} : @_;

  return $class->$orig(
                       map  { $_ => $params{$_} }
                       grep { defined $params{$_} }
                       keys %params
                      );
};

__PACKAGE__->meta->make_immutable;

no Moose;

1;

__END__

=head1 NAME

WTSI::NPG::HTS::PacBio::Metadata

=head1 DESCRIPTION

Represents excerpts of the PacBio metadata created per SMRT cell.

=head1 AUTHOR

Keith James E<lt>kdj@sanger.ac.ukE<gt>

=head1 COPYRIGHT AND DISCLAIMER

Copyright (C) 2016 Genome Research Limited. All Rights Reserved.

This program is free software: you can redistribute it and/or modify
it under the terms of the Perl Artistic License or the GNU General
Public License as published by the Free Software Foundation, either
version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

=cut
