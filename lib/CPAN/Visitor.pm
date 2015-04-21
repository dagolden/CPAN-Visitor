use 5.006;
use strict;
use warnings;
package CPAN::Visitor;
# ABSTRACT: Generic traversal of distributions in a CPAN repository

our $VERSION = '0.005';

use autodie;

use Archive::Extract 0.34 ();
use File::Find ();
use File::pushd 1.00 ();
use File::Temp 0.20 ();
use Path::Class 0.17 ();
use Parallel::ForkManager 0.007005 ();

use Moose 0.93 ;
use MooseX::Params::Validate 0.13;
use namespace::autoclean 0.09 ;

has 'cpan'  => ( is => 'ro', required => 1 );
has 'quiet' => ( is => 'rw', default => 1 );
has 'stash' => ( is => 'ro', isa => 'HashRef',  default => sub { {} } );
has 'files' => ( is => 'ro', isa => 'ArrayRef', default => sub { [] } );

sub BUILD {
  my $self = shift;
  unless (
    -d $self->cpan &&
    -d Path::Class::dir($self->cpan, 'authors', 'id')
  ) {
    die "'cpan' parameter must be the root of a CPAN repository";
  }
}

#--------------------------------------------------------------------------#
# selection methods
#--------------------------------------------------------------------------#

my $archive_re = qr{\.(?:tar\.(?:bz2|gz|Z)|t(?:gz|bz)|zip)$}i;

sub select {
  my ($self, %params) = validated_hash( \@_,
    match    => { isa => 'RegexpRef | ArrayRef[RegexpRef]', default => [qr/./] },
    exclude  => { isa => 'RegexpRef | ArrayRef[RegexpRef]', default => [] },
    subtrees => { isa => 'Str | ArrayRef[Str]', default => [] },
    all_files => { isa => 'Bool', default => 0 },
    append => { isa => 'Bool', default => 0 },
  );

  # normalize to arrayrefs
  for my $k ( qw/match exclude subtrees/ ) {
    next unless exists $params{$k};
    next if ref $params{$k} && ref $params{$k} eq 'ARRAY';
    $params{$k} = [ $params{$k} ];
  }

  # determine search dirs
  my $id_dir = Path::Class::dir($self->cpan, qw/authors id/);
  my @search_dirs = map { $id_dir->subdir($_)->stringify } @{$params{subtrees}};
  @search_dirs = $id_dir->stringify if ! @search_dirs;

  # perform search
  my @found;
  File::Find::find(
    {
      no_chdir => 1,
      follow => 0,
      preprocess => sub { my @files = sort @_; return @files },
      wanted => sub {
        return unless -f;
        return unless $params{all_files} || /$archive_re/;
        for my $re ( @{$params{exclude}} ) {
          return if /$re/;
        }
        for my $re ( @{$params{match}} ) {
          return if ! /$re/;
        }
        (my $f = Path::Class::file($_)->relative($id_dir)) =~ s{./../}{};
        push @found, $f;
      }
    },
    @search_dirs,
  );

  if ( $params{append} ) {
    push @{$self->files}, @found;
  }
  else {
    @{$self->files} = @found;
  }
  return scalar @found;
}

#--------------------------------------------------------------------------#
# default actions
#
# These are passed a "job" hashref. It is initialized with the following
# fields:
#
#   distfile -- e.g. DAGOLDEN/CPAN-Visitor-0.001.tar.gz
#   distpath -- e.g. /my/cpan/authors/id/D/DA/DAGOLDEN/CPAN-Visitor-0.001.tar.gz
#   tempdir  -- File::Temp directory object for extraction or other things
#   stash    -- the 'stash' hashref from the Visitor object
#   quiet    -- the 'quiet' flag from the Visitor object
#   result   -- an empty hashref to start; the return values from each
#               action are added and may be referenced by subsequent actions
#
# E.g. the return value from 'extract' is the directory:
#
#   $job->{result}{extract} = $unpacked_directory;
#
#--------------------------------------------------------------------------#

sub _check { 1 } # always proceed

sub _start { 1 } # no special start action

# _extract returns the proper directory to chdir into
# if the $job->{stash}{prefer_bin} is true, it will tell Archive::Extract
# to use binaries
sub _extract {
  my $job = shift;
  local $Archive::Extract::DEBUG = 0;
  local $Archive::Extract::PREFER_BIN = $job->{stash}{prefer_bin} ? 1 : 0;
  local $Archive::Extract::WARN = $job->{quiet} ? 0 : 1;

  # cd to tmpdir for duration of this sub
  my $pushd = File::pushd::pushd( $job->{tempdir} );

  my $ae = Archive::Extract->new( archive => $job->{distpath} );

  my $olderr;

  # stderr > /dev/null if quiet
  if ( ! $Archive::Extract::WARN ) {
    open $olderr, ">&STDERR";
    open STDERR, ">", File::Spec->devnull;
  }

  my $extract_ok = $ae->extract;

  # restore stderr if quiet
  if ( ! $Archive::Extract::WARN ) {
    open STDERR, ">&", $olderr;
    close $olderr;
  }

  if ( ! $extract_ok ) {
    warn "Couldn't extract '$job->{distpath}'\n" if $Archive::Extract::WARN;
    return;
  }

  # most distributions unpack a single directory that we must enter
  # but some behave poorly and unpack to the current directory
  my @children = Path::Class::dir()->children;
  if ( @children == 1 && -d $children[0] ) {
    return Path::Class::dir($job->{tempdir}, $children[0])->absolute->stringify;
  }
  else {
    return Path::Class::dir($job->{tempdir})->absolute->stringify;
  }
}

sub _enter {
  my $job = shift;
  my $curdir = Path::Class::dir()->absolute;
  my $target_dir = $job->{result}{extract} or return;
  if ( -d $target_dir ) {
    chmod 0755, $target_dir unless -x $target_dir;
    chdir $target_dir;
  }
  else {
    warn "Can't chdir to directory '$target_dir'\n"
      unless $job->{quiet};
    return;
  }
  return $curdir;
}

sub _visit { 1 } # do nothing

# chdir out and clean up
sub _leave {
  my $job = shift;
  chdir $job->{result}{enter};
  return 1;
}

sub _finish { 1 } # no special finish action

#--------------------------------------------------------------------------#
# iteration methods
#--------------------------------------------------------------------------#

# iterate()
#
# Arguments:
#
#   jobs -- if greater than 1, distributions are processed in parallel
#           via Parallel::ForkManager
#
# iterate() takes several optional callbacks which are run in the following
# order.  Callbacks get a single hashref argument as described above under
# default actions.
#
#   check -- whether the distribution should be processed; goes to next file
#            if false; default is always true
#
#   start -- used for any setup, logging, etc; default does nothing
#
#   extract -- extracts a distribution into a temp directory or otherwise
#              prepares for visiting; skips to finish action if it returns
#              a false value; default returns the path to the extracted
#              directory
#
#   enter -- skips to the finish action if it returns false; default takes
#            the result of extract, chdir's into it, and returns the
#            original directory
#
#   visit -- examine the distribution or otherwise do stuff; the default
#            does nothing;
#
#   leave -- default returns to the original directory (the result of enter)
#
#   finish -- any teardown processing, logging, etc.

sub iterate {
  my ($self, %params) = validated_hash( \@_,
    jobs    => { isa => 'Int', default => 0 },
    check   => { isa => 'CodeRef', default => \&_check },
    start   => { isa => 'CodeRef', default => \&_start },
    extract => { isa => 'CodeRef', default => \&_extract },
    enter   => { isa => 'CodeRef', default => \&_enter },
    visit   => { isa => 'CodeRef', default => \&_visit },
    leave   => { isa => 'CodeRef', default => \&_leave },
    finish  => { isa => 'CodeRef', default => \&_finish },
  );

  my $pm = Parallel::ForkManager->new( $params{jobs} > 1 ? $params{jobs} : 0 );
  for my $distfile ( @{ $self->files } ) {
    $pm->start and next;
    eval { $self->_iterate($distfile, \%params) };
    warn "Error visiting $distfile: $@\n" if $@ && ! $self->quiet;
    $pm->finish;
  }
  $pm->wait_all_children;
  return 1;
}

sub _iterate {
  my ($self, $distfile, $params) = @_;
  my $job = {
    distfile  => $distfile,
    distpath  => $self->_fullpath($distfile),
    tempdir   => File::Temp->newdir(),
    stash     => $self->stash,
    quiet     => $self->quiet,
    result    => {},
  };
  $job->{result}{check} = $params->{check}->($job) or return;
  $job->{result}{start} = $params->{start}->($job);
  ACTION: {
    $job->{result}{extract} = $params->{extract}->($job) or last ACTION;
    $job->{result}{enter} = $params->{enter}->($job) or last ACTION;
    $job->{result}{visit} = $params->{visit}->($job);
    $job->{result}{leave} = $params->{leave}->($job);
  }
  $params->{finish}->($job);
  return;
}

sub _fullpath {
  my ($self, $distfile) = @_;
  my ($two, $one) = $distfile =~ /\A((.).)/;
  return Path::Class::file(
    $self->cpan, 'authors', 'id', $one, $two, $distfile
  )->absolute->stringify;
}

__PACKAGE__->meta->make_immutable;

1;

__END__

=for Pod::Coverage BUILD

=head1 SYNOPSIS

    use CPAN::Visitor;
    my $visitor = CPAN::Visitor->new( cpan => "/path/to/cpan" );

    # Prepare to visit all distributions
    $visitor->select();

    # Or a subset of distributions
    $visitor->select(
      subtrees => [ 'D/DA', 'A/AD' ], # relative to authors/id/
      exclude => qr{/Acme-},          # No Acme- dists
      match => qr{/Test-}             # Only Test- dists
    );

    # Action is specified via a callback
    $visitor->iterate(
      visit => sub {
        my $job = shift;
        print $job->{distfile} if -f 'Build.PL'
      }
    );

    # Or start with a list of files
    $visitor = CPAN::Visitor->new(
      cpan => "/path/to/cpan",
      files => \@distfiles,     # e.g. ANDK/CPAN-1.94.tar.gz
    );
    $visitor->iterate( visit => \&callback );

    # Iterate in parallel
    $visitor->iterate( visit => \&callback, jobs => 5 );

=head1 DESCRIPTION

A very generic, callback-driven program to iterate over a CPAN repository.

Needs better documentation and tests, but is provided for others to examine,
use or contribute to.

=head1 USAGE

=head2 new

  my $visitor = CPAN::Visitor->new( @args );

Object attributes include:

=for :list
* C<cpan> — path to CPAN or mini CPAN repository. Required.
* C<quiet> — whether warnings should be silenced (e.g. from extraction).
  Optional.
* C<stash> — hash-ref of user-data to be made available during iteration.
  Optional.
* C<files> — array-ref with a pre-selection of of distribution files.  These
  must be in AUTHOR/NAME.suffix format. Optional.

=head2 select

  $visitor->select( @args );

Valid arguments include:

=for :list
* C<subtrees> — path or array-ref of paths to search.  These must be relative
  to the 'authors/id/' directory within a CPAN repo.  If given, only files
  within those subtrees will be considered. If not specified, the entire
  'authors/id' tree is searched.
* C<exclude> — qr() or array-ref of qr() patterns.  If a path matches *any*
  pattern, it is excluded
* C<match> — qr() or array-ref of qr() patterns.  If an array-ref is provided,
  only paths that match *all* patterns are included
* all_files — boolean that determines whether all files or only files that
  have a distribution archive suffix are selected.  Default is false.
* append — boolean that determines whether the selected files should be
  appended to previously selected files. The default is false, which replaces
  any previous selection

The C<select> method returns a count of files selected.

=head2 iterate

 $visitor->iterate( @args );

Valid arguments include:

=for :list
* C<jobs> — non-negative integer specifying the maximum number of forked
  processes. Defaults to none.
* C<check> — code reference callback
* C<start> — code reference callback
* C<extract> — code reference callback
* C<enter> — code reference callback
* C<visit> — code reference callback
* C<leave> — code reference callback
* C<finish> — code reference callback

See L</ACTION CALLBACKS> for more.  Generally, you only need to provide the
C<visit> callback, which is called from inside the unpacked distribution
directory.

The C<iterate> method always returns true.

=head1 ACTION CALLBACKS

Each selected distribution is processed with a series of callback
functions.  These are each passed a hash-ref with information about
the particular distribution being processed.

  sub _my_visit {
    my $job = shift;
    # do stuff
  }

The job hash-ref is initialized with the following fields:

=for :list
* C<distfile> — the unique, short CPAN distfile name, e.g.
  DAGOLDEN/CPAN-Visitor-0.001.tar.gz
* C<distpath> — the absolute path the distribution archive, e.g.
  /my/cpan/authors/id/D/DA/DAGOLDEN/CPAN-Visitor-0.001.tar.gz
* C<tempdir>  — a File::Temp directory object for extraction or other things
* C<stash>    — the 'stash' hashref from the Visitor object
* C<quiet>    — the 'quiet' flag from the Visitor object
* C<result>   — an empty hashref to start; the return values from each action
  are added and may be referenced by subsequent actions

The C<result> field is used to accumulate the return values from action
callbacks.  For example, the return value from the default 'extract' action is
the unpacked distribution directory:

  $job->{result}{extract} # distribution directory path

You do not need to store the results yourself — the C<iterate> method
takes care of it for you.

Callbacks occur in the following order.  Some callbacks skip further
processing if the return value is false.

=for :list
* C<check> — determines whether the distribution should be processed; goes to
  next file if false; default is always true
* C<start> — used for any setup, logging, etc; default does nothing
* C<extract> — operate on the tarball to prepare for visiting; skips to finish
  action if it returns a false value; the default extracts a distribution into
  a temp directory and returns the path to the extracted directory; if the
  C<stash> has a true value for C<prefer_bin>, binary tar, etc. will be
  preferred.  This is faster, but less portable.
* C<enter> — skips to the finish action if it returns false; default takes the
  result of extract, chdir's into it, and returns the original directory; if
  the extract result is missing the +x permissions, this will attempt to add it
  before calling chdir.
* C<visit> — examine the distribution or otherwise do stuff; the default does
  nothing;
* C<leave> — default returns to the original directory (the result of enter)
* C<finish> — any teardown processing, logging, etc.

These allow complete customization of the iteration process.  For example,
one could do something like this:

=for :list
* replace the default C<extract> callback with one that returns an arrayref of
  distribution files without actually unpacking it into a physical directory
* replace the default C<enter> callback with one that does nothing but return a
  true value; replace the default C<leave> callback likewise
* have the C<visit> callback get the C<< $job->{result}{extract} >> listing and
  examine it for the presence of certain files

This could potentially speed up iteration if only the file names within
the distribution are of interest and not the contents of the actual files.

=head1 SEE ALSO

=for :list
* L<App::CPAN::Mini::Visit>
* L<CPAN::Mini::Visit>

=cut

