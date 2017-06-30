package WTSI::NPG::HTS::ONT::MinIONRunPublisherTest;

use strict;
use warnings;

use Archive::Tar;
use English qw[-no_match_vars];
use File::Basename;
use File::Copy;
use File::Spec::Functions qw[catfile];
use File::Path qw[make_path];
use File::Temp;
use Log::Log4perl;
use List::AllUtils qw[uniq];
use Test::More;

use base qw[WTSI::NPG::HTS::Test];

use WTSI::NPG::HTS::ONT::MinIONRunPublisher;
use WTSI::NPG::iRODS;
use WTSI::NPG::iRODS::DataObject;
use WTSI::NPG::iRODS::Metadata;

Log::Log4perl::init('./etc/log4perl_tests.conf');

my $pid          = $PID;
my $test_counter = 0;
my $data_path    = 't/data/ont/minion/run_a/basecalled/pass';

my $irods_tmp_coll;

sub setup_test : Test(setup) {
  my $irods = WTSI::NPG::iRODS->new(environment          => \%ENV,
                                    strict_baton_version => 0);

  $irods_tmp_coll =
    $irods->add_collection("MinIONRunPublisherTest.$pid.$test_counter");
  $test_counter++;
}

sub teardown_test : Test(teardown) {
  my $irods = WTSI::NPG::iRODS->new(environment          => \%ENV,
                                    strict_baton_version => 0);
  $irods->remove_collection($irods_tmp_coll);
}

sub publish_files : Test(39) {
  my $staging_dir    = File::Temp->newdir->dirname;
  my $runfolder_path = "$staging_dir/run_a";
  my $pass_dir       = "$runfolder_path/basecalled/pass";
  make_path($pass_dir);

  my $dest_coll = $irods_tmp_coll;
  my $arch_capacity = 12;

  my $pid = fork();
  die "Failed to fork a test process" unless defined $pid;

  if ($pid == 0) {
    my $pub = WTSI::NPG::HTS::ONT::MinIONRunPublisher->new
      (arch_capacity   => $arch_capacity,
       arch_timeout    => 10,
       dest_collection => $dest_coll,
       runfolder_path  => $runfolder_path,
       session_timeout => 30);

    my ($tar_count, $num_errors) = $pub->publish_files;

    exit $num_errors;
  }

  sleep 5;

  opendir my $dh, $data_path or die "Failed to opendir '$data_path': $!";
  my @fast5_files = map { catfile($data_path, $_) }
    grep { m{[.]fast5$}msx } readdir $dh;
  closedir $dh;

  my $fast5_count = scalar @fast5_files;

  # Simulate writing new fast5 files
  foreach my $file (@fast5_files) {
    copy($file, $pass_dir) or die "Failed to copy $file: $ERRNO";
  }

  waitpid($pid, 0);
  cmp_ok($CHILD_ERROR, '==', 0, 'Publisher exited cleanly');

  # Check the manifest
  my $manifest_file     = 'MN12345_FNFAF12345_20170331.txt';
  my $expected_manifest = "$runfolder_path/$manifest_file";

  ok(-e $expected_manifest, "Manifest file '$expected_manifest' exists");

  my %manifest;
  open my $fh, '<', $expected_manifest or
    die "Failed to open manifest '$expected_manifest': $ERRNO";
  while (my $line = <$fh>) {
    chomp $line;

    my ($tar_path, $fast5_path) = split /\t/msx, $line;
    $manifest{$fast5_path} = $tar_path;
  }
  close $fh or die "Failed to close '$expected_manifest': $ERRNO";

  cmp_ok(scalar uniq(values %manifest), '==', 3, 'Manifest lists 3 tar files')
    or diag explain \%manifest;

  # Count the tar files created in iRODS
  my $irods = WTSI::NPG::iRODS->new;

  my $tar_coll = "$dest_coll/MN12345/FNFAF12345";
  my ($observed_paths) = $irods->list_collection($tar_coll);
  my @observed_paths = @{$observed_paths};
  my $num_expected = 3;
  cmp_ok(scalar @observed_paths, '==', $num_expected,
         "Published $num_expected tar files") or
           diag explain \@observed_paths;

  # Fetch the MD5 metadata
  my @observed_md5_metadata;
  foreach my $path (@observed_paths) {
    my $obj = WTSI::NPG::iRODS::DataObject->new($irods, $path);
    my @avu = $obj->find_in_metadata($FILE_MD5);
    cmp_ok(scalar @avu, '==', 1, 'Single md5 attribute present');
    push @observed_md5_metadata, $avu[0]->{value};
  }

  # Fetch the tar file data objects from iRODS and calculate their MD5s
  my @observed_md5_checksums;
  my @observed_file_counts;
  foreach my $tar (@observed_paths) {
    my $filename = fileparse($tar);
    my $file = $irods->get_object($tar, catfile($staging_dir, $filename));

    my $md5 = $irods->md5sum($file);
    push @observed_md5_checksums, $md5;

    my $arch = Archive::Tar->new;
    $arch->read($file);
    my @entries = $arch->list_files;
    push @observed_file_counts, scalar @entries;

    foreach my $entry (@entries) {
      # Caculate original fast5 file from tar entry relative path
      my $entry_file = catfile($runfolder_path, $entry);
      # Look up the tar file iRODS data object in the manifest
      my $manifest_tar = $manifest{$entry_file};
      is($tar, $manifest_tar,
         "Manifest describes tar data object for '$entry_file'");
    }
  }

  is_deeply(\@observed_md5_checksums, \@observed_md5_metadata,
            'MD5 checksums and metadata concur') or
              diag explain [\@observed_md5_checksums,
                            \@observed_md5_metadata];

  my @expected_file_counts = ($arch_capacity, $arch_capacity,
                              $fast5_count - $arch_capacity * 2);
  is_deeply(\@observed_file_counts, \@expected_file_counts ,
            'Expected file counts') or
              diag explain \@observed_file_counts;

}

1;
