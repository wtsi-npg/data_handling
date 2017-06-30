package WTSI::NPG::HTS::ONT::MinIONRunMonitor;

use namespace::autoclean;

use Data::Dump qw[pp];
use English qw[-no_match_vars];
use File::Spec::Functions qw[abs2rel catfile splitpath];
use IO::Select;
use Linux::Inotify2;
use Moose;
use MooseX::StrictConstructor;
use Parallel::ForkManager;
use POSIX;
use Try::Tiny;

use WTSI::NPG::HTS::ONT::MinIONRunPublisher;

with qw[
         WTSI::DNAP::Utilities::Loggable
       ];

our $VERSION = '';

our $SELECT_TIMEOUT = 2;

##no critic (ValuesAndExpressions::ProhibitMagicNumbers)
has 'staging_path' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 1,
   documentation => 'The directory in which MinION runfolders appear');

has 'tar_capacity' =>
  (isa           => 'Int',
   is            => 'ro',
   required      => 1,
   default       => 10_000,
   documentation => 'The maximum number of files that will be added to any ' .
                    'tar file. Increasing this number will result in ' .
                    'connections to iRODS being open for longer');

has 'tar_timeout' =>
  (isa           => 'Int',
   is            => 'ro',
   required      => 1,
   default       => 60 * 5,
   documentation => 'The number of seconds idle time since the previous ' .
                    'file was added to an open tar archive, after which ' .
                    'the archive will be closed will be closed, even if ' .
                    'not at capacity');

has 'session_timeout' =>
  (isa           => 'Int',
   is            => 'ro',
   required      => 1,
   default       => 60 * 20,
   documentation => 'The number of seconds idle time (no files added) ' .
                    'after which it will be ended automatically');

has 'max_processes' =>
  (isa           => 'Int',
   is            => 'ro',
   required      => 1,
   default       => 50,
   documentation => 'The maximum number of child processes to fork');

has 'inotify' =>
  (isa           => 'Linux::Inotify2',
   is            => 'ro',
   required      => 1,
   builder       => '_build_inotify',
   lazy          => 1,
   documentation => 'The inotify instance');

has 'event_queue' =>
  (isa           => 'ArrayRef',
   is            => 'ro',
   required      => 1,
   default       => sub { return [] },
   documentation => 'A queue of Linux::Inotify2::Event objects to be ' .
                    'processed. Inotify callbacks push events here');
##use critic

sub start {
  my ($self) = @_;

  my $select = IO::Select->new;
  $select->add($self->inotify->fileno);
  my $watch = $self->_start_watch;

  my %in_progress; # Map runfolder path to PID

  $self->info(sprintf
              q[Started MinIONRunMonitor; staging path: '%s', ] .
              q[tar capacity: %d files, tar timeout %d sec ] .
              q[max processes: %d, session timeout %d sec],
              $self->staging_path, $self->tar_capacity, $self->tar_timeout,
              $self->max_processes, $self->session_timeout);

  my $pm = Parallel::ForkManager->new($self->max_processes);

  # Use callbacks to track running processes
  $pm->run_on_start(sub {
                      my ($pid, $name) = @_;
                      $self->debug("Process $name (PID $pid) started");
                      $in_progress{$name} = $pid;
                    });
  $pm->run_on_finish(sub {
                       my ($pid, $exit_code, $name) = @_;
                       $self->debug("Process $name (PID $pid) completed ".
                                    "with exit code: $exit_code");
                       delete $in_progress{$name};
                     });

  $pm->run_on_wait(sub { $self->debug('Waiting for a child process...') }, 2);

  my $continue   = 1; # While true, continue monitoring
  my $num_errors = 0;

  # Ensure a clean exit on SIGTERM
  local $SIG{TERM} = sub { $continue = 0 };

  try {
    while ($continue) {
      $self->debug('Continue ...');
      if ($select->can_read($SELECT_TIMEOUT)) {
        my $n = $self->inotify->poll;
        $self->debug("$n events");
      }

      if (@{$self->event_queue}) {
        $self->debug(scalar @{$self->event_queue}, ' events in queue');

      EVENT: while (my $event = shift @{$self->event_queue}) {
          # Parent process
          my $abs_path    = $event->fullname;
          my $current_pid = $in_progress{$abs_path};
          if ($current_pid) {
            $self->debug("$abs_path is already being monitored by process ",
                         "with PID $current_pid");
            next EVENT;
          }

          my $minion_id = $self->_get_minion_id($abs_path);
          if (not $minion_id) {
            next EVENT;
          }

          my $pid = $pm->start($abs_path) and next EVENT;

          # Child process
          $self->info("Started MinIONRunPublisher with PID $pid on ",
                      "'$abs_path' (MinION $minion_id)");

          my $publisher = WTSI::NPG::HTS::ONT::MinIONRunPublisher->new
            (dest_collection => '/Sanger1/home/kdj',
             minion_id       => $minion_id,
             runfolder_path  => $abs_path,
             session_timeout => 200,
             tar_capacity    => 10,
             tar_timeout     => 300);

          my ($nf, $ne) = $publisher->publish_files;
          my $exit_code = $ne == 0 ? 0 : 1;
          $self->info("Finished publishing $nf files for MinION $minion_id ",
                      "with $ne errors and exit code $exit_code");

          $pm->finish($exit_code);
        }
      }
      else {
        $self->debug("Select timeout ($SELECT_TIMEOUT sec) ...");
        $self->debug('Running processes with PIDs ', pp($pm->running_procs));
        $pm->reap_finished_children;
      }
    }
  } catch {
    $self->error($_);
    $num_errors++;
  };

  if (defined $watch) {
    $watch->cancel;
  }
  $select->remove($self->inotify->fileno);

  return $num_errors;
}

sub _build_inotify {
  my ($self) = @_;

  my $inotify = Linux::Inotify2->new or
    $self->logcroak("Failed to create a new Linux::Inotify2 object: $ERRNO");

  return $inotify;
}

sub _start_watch {
  my ($self) = @_;

  my $path   = $self->staging_path;
  my $events = IN_MOVED_TO | IN_CREATE | IN_MOVED_FROM | IN_DELETE | IN_ATTRIB;
  my $cb     = $self->_make_callback;
  my $watch  = $self->inotify->watch($path, $events, $cb);

  if (defined $watch) {
    $self->debug("Started watch on '$path'");
  }
  else {
    $self->logconfess("Failed to start watch on '$path'");
  }

  return $watch;
}

sub _make_callback {
  my ($self) = @_;

  my $inotify     = $self->inotify;
  my $event_queue = $self->event_queue;

  return sub {
    my $event = shift;

    if ($event->IN_Q_OVERFLOW) {
      $self->warn('Some events were lost!');
    }

    if ($event->IN_CREATE or $event->IN_MOVED_TO or $event->IN_ATTRIB) {
      if ($event->IN_ISDIR) {
        my $path = $event->fullname;

        # Path added was a directory; add the event to the queue, to be
        # handled in the main loop
        $self->debug("Event IN_CREATE/IN_MOVED_TO/IN_ATTRIB on '$path'");
        push @{$event_queue}, $event;
      }
    }

    # Path was removed from the watched hierarchy
    if ($event->IN_DELETE or $event->IN_MOVED_FROM) {
      if ($event->IN_ISDIR) {
        my $path = $event->fullname;
        $self->debug("Event IN_DELETE/IN_MOVED_FROM on '$path'");
      }
    }
  };
}

sub _get_minion_id {
  my ($self, $path) = @_;

  $self->debug("Identifying a MinION ID from fast5 files under '$path'");
  my ($hostname, $run_date, $asic_id, $minion_id);

  my $file = $self->_find_fast5_file($path);
  if ($file) {
    ($hostname, $run_date, $asic_id, $minion_id) =
      $self->_parse_file_name($file);
    if (not $minion_id) {
      $self->error("Failed to parse a MinION ID from '$file'");
    }
  }
  else {
    $self->warn("Failed to find any fast5 file in '$path'");
  }

  return $minion_id;
}

# Expect to find a fast5 file in /<staging path>/<run folder>/[0-9]+/
sub _find_fast5_file {
  my ($self, $path) = @_;

  $self->debug("Looking for numbered subdirectories in '$path'");

  opendir my $dh1, $path or
    $self->logcroak("Failed to opendir '$path': $ERRNO");

  my @dirs = grep { -d } map { "$path/$_" }
    grep { m{^\d+$}msx } readdir $dh1;
  closedir $dh1;

  my $fast5_file;
  foreach my $dir (@dirs) {
    $self->debug("Checking for fast5 files in '$dir'");

    opendir my $dh2, $dir or
      $self->logcroak("Failed to opendir '$dir': $ERRNO");

    my @files = grep { -f } map { "$dir/$_" }
      grep { m{[.]fast5$}msx } readdir $dh2;
    closedir $dh2;

    if (@files) {
      $fast5_file = shift @files;
      last;
    }
  }

  return $fast5_file;
}

sub _parse_file_name {
  my ($self, $path) = @_;

  my ($volume, $dirs, $file) = splitpath($path);
  my ($hostname, $run_date, $asic_id, $minion_id) = split /_/msx, $file;

  return ($hostname, $run_date, $asic_id, $minion_id);
}

__PACKAGE__->meta->make_immutable;

no Moose;

1;


__END__

=head1 NAME

WTSI::NPG::HTS::ONT::MinIONRunMonitor

=head1 DESCRIPTION



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
