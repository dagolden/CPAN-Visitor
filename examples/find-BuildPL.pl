use strict;
use warnings;
use CPAN::Visitor;
use CPAN::Mini;
use Getopt::Long;

my $jobs = 0;
GetOptions( 'jobs:i' => \$jobs );

my %config = CPAN::Mini->read_config;
die "Must specific 'local: <path>' in .minicpanrc\n"
  unless $config{local};

my $visitor = CPAN::Visitor->new( cpan => $config{local} );

# or a subset of distributions
$visitor->select( exclude => qr{/Acme-} );

# Action is specified via a callback
$visitor->iterate(
  jobs => $jobs,
  visit => sub {
    my $job = shift;
    print "$job->{distfile}\n" if -f 'Build.PL'
  }
);


